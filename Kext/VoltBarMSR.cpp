// VoltBarMSR — minimal, hardened MSR access driver for VoltBar (replacement for VoltageShift.kext).
// License: GPL-3.0.
//
// Differences from VoltageShift's AnVMSR:
//   * only root (administrator privilege) can open a connection;
//   * reads go through rdmsr_carefully(), so a non-existent MSR returns an error instead of a #GP panic;
//   * writes are allowed only to a small whitelist of registers, and reserved bits are masked off,
//     so a bad value can't trigger a #GP in the kernel;
//   * IA32_MISC_ENABLE (Turbo), TEMPERATURE_TARGET (TjMax offset) and POWER_CTL (BD PROCHOT) are changed
//     on every logical CPU, and only the one documented field is touched;
//   * TURBO_RATIO_LIMIT can never be set above the factory single-core turbo ratio captured when the
//     driver starts (this is what makes it safe on multiplier-locked CPUs).
//
// User client interface (IOConnectCallScalarMethod):
//   selector 0  read : in [msr]          -> out [value]
//   selector 1  write: in [msr, value]   -> out [value read back]
//   selector 2  info : in []             -> out [interface version]

#include <IOKit/IOService.h>
#include <IOKit/IOUserClient.h>
#include <IOKit/IOLib.h>
#include <libkern/OSAtomic.h>

extern "C" {
int  rdmsr_carefully(uint32_t msr, uint32_t *lo, uint32_t *hi);
void mp_rendezvous_no_intrs(void (*action_func)(void *), void *arg);
}

#define VBMSR_INTERFACE_VERSION 2

// MARK: - Low level

static inline void vb_wrmsr(uint32_t msr, uint64_t value) {
    __asm__ volatile ("wrmsr" : : "c"(msr), "a"((uint32_t)value), "d"((uint32_t)(value >> 32)));
}

static inline uint64_t vb_rdmsr(uint32_t msr) {
    uint32_t lo, hi;
    __asm__ volatile ("rdmsr" : "=a"(lo), "=d"(hi) : "c"(msr));
    return ((uint64_t)hi << 32) | lo;
}

static IOReturn safeRead(uint32_t msr, uint64_t *out) {
    uint32_t lo = 0, hi = 0;
    if (rdmsr_carefully(msr, &lo, &hi) != 0) return kIOReturnUnsupported;
    *out = ((uint64_t)hi << 32) | lo;
    return kIOReturnSuccess;
}

// MARK: - Write whitelist

enum : uint32_t {
    MSR_OC_MAILBOX      = 0x150,
    MSR_PERF_CTL        = 0x199,
    MSR_PLATFORM_INFO   = 0xCE,
    MSR_MISC_ENABLE     = 0x1A0,
    MSR_TEMP_TARGET     = 0x1A2,
    MSR_TURBO_RATIO     = 0x1AD,
    MSR_POWER_CTL       = 0x1FC,
    MSR_PKG_POWER_LIMIT = 0x610,
    MSR_PP0_POWER_LIMIT = 0x638,
    MSR_PP1_POWER_LIMIT = 0x640,
};

static const uint64_t TURBO_DISABLE_BIT  = 1ULL << 38;          // MISC_ENABLE
static const uint64_t TCC_OFFSET_MASK    = 0xFULL << 24;          // TEMPERATURE_TARGET 27:24
static const uint64_t BD_PROCHOT_BIT     = 1ULL << 0;             // POWER_CTL
static const uint64_t PI_RATIO_PROG_BIT  = 1ULL << 28;            // PLATFORM_INFO: turbo ratios programmable
static const uint64_t PI_TJ_PROG_BIT     = 1ULL << 30;            // PLATFORM_INFO: TjMax offset programmable

// Factory single-core turbo ratio, captured once at driver start. 0 = unknown -> ratio writes refused.
static uint8_t gMaxTurboRatio = 0;

struct MaskedArgs { uint32_t msr; uint64_t mask; uint64_t bits; volatile SInt32 errors; };

// Runs on every logical CPU with interrupts disabled: replaces only `mask` bits of `msr` with `bits`.
static void maskedAction(void *arg) {
    MaskedArgs *a = (MaskedArgs *)arg;
    uint32_t lo, hi;
    if (rdmsr_carefully(a->msr, &lo, &hi) != 0) { OSIncrementAtomic(&a->errors); return; }
    uint64_t v = ((uint64_t)hi << 32) | lo;
    uint64_t n = (v & ~a->mask) | (a->bits & a->mask);
    if (n != v) vb_wrmsr(a->msr, n);
}

static IOReturn writeMaskedAllCPUs(uint32_t msr, uint64_t mask, uint64_t value) {
    MaskedArgs a = { msr, mask, value, 0 };
    mp_rendezvous_no_intrs(maskedAction, &a);
    return a.errors ? kIOReturnIOError : kIOReturnSuccess;
}

static bool platformInfoBit(uint64_t bit) {
    uint64_t pi = 0;
    return safeRead(MSR_PLATFORM_INFO, &pi) == kIOReturnSuccess && (pi & bit);
}

static IOReturn safeWrite(uint32_t msr, uint64_t value, uint64_t *readBack) {
    uint64_t cur = 0;
    IOReturn r = safeRead(msr, &cur);   // the register must exist before we write to it
    if (r != kIOReturnSuccess) return r;

    switch (msr) {
    case MSR_OC_MAILBOX:
        // Mailbox request: bit 63 = run/busy, 32..47 = command/domain, 0..31 = data.
        vb_wrmsr(msr, value & 0x8000FFFFFFFFFFFFULL);
        break;

    case MSR_PERF_CTL:
        // Target ratio (bits 0..15) and IDA/Turbo disengage (bit 32) only.
        vb_wrmsr(msr, (cur & ~0x10000FFFFULL) | (value & 0x10000FFFFULL));
        break;

    case MSR_MISC_ENABLE:
        r = writeMaskedAllCPUs(msr, TURBO_DISABLE_BIT, value);
        if (r != kIOReturnSuccess) return r;
        break;

    case MSR_TEMP_TARGET:
        if (!platformInfoBit(PI_TJ_PROG_BIT)) return kIOReturnNotWritable;
        r = writeMaskedAllCPUs(msr, TCC_OFFSET_MASK, value);
        if (r != kIOReturnSuccess) return r;
        break;

    case MSR_POWER_CTL:
        r = writeMaskedAllCPUs(msr, BD_PROCHOT_BIT, value);
        if (r != kIOReturnSuccess) return r;
        break;

    case MSR_TURBO_RATIO: {
        // Bytes 0..3 = max ratio with 1..4 active cores. Never above the factory 1-core ratio,
        // never 0, and non-increasing with more active cores.
        if (!platformInfoBit(PI_RATIO_PROG_BIT) || gMaxTurboRatio == 0) return kIOReturnNotWritable;
        uint64_t n = cur & ~0xFFFFFFFFULL;
        uint8_t prev = gMaxTurboRatio;
        for (int i = 0; i < 4; i++) {
            uint8_t b = (uint8_t)(value >> (8 * i));
            if (b == 0 || b > prev) return kIOReturnBadArgument;
            n |= (uint64_t)b << (8 * i);
            prev = b;
        }
        vb_wrmsr(msr, n);
        break;
    }

    case MSR_PKG_POWER_LIMIT:
        if (cur >> 63) return kIOReturnNotWritable;                       // locked by firmware
        vb_wrmsr(msr, value & 0x00FFFFFF00FFFFFFULL);                     // never set lock / reserved bits
        break;

    case MSR_PP0_POWER_LIMIT:
    case MSR_PP1_POWER_LIMIT:
        if (cur & (1ULL << 31)) return kIOReturnNotWritable;
        vb_wrmsr(msr, (cur & ~0x00FFFFFFULL) | (value & 0x00FFFFFFULL));
        break;

    default:
        return kIOReturnNotPermitted;
    }

    if (readBack) *readBack = vb_rdmsr(msr);
    return kIOReturnSuccess;
}

// MARK: - Service

class VoltBarMSR : public IOService {
    OSDeclareDefaultStructors(VoltBarMSR)
public:
    bool start(IOService *provider) override;
    void stop(IOService *provider) override;
};

OSDefineMetaClassAndStructors(VoltBarMSR, IOService)

bool VoltBarMSR::start(IOService *provider) {
    if (!IOService::start(provider)) return false;
    uint64_t probe;
    if (safeRead(0x198 /* IA32_PERF_STATUS */, &probe) != kIOReturnSuccess) {
        IOLog("VoltBarMSR: MSR access not available on this CPU\n");
        return false;
    }
    uint64_t ratios = 0;
    if (safeRead(MSR_TURBO_RATIO, &ratios) == kIOReturnSuccess) gMaxTurboRatio = (uint8_t)(ratios & 0xFF);
    setProperty("InterfaceVersion", VBMSR_INTERFACE_VERSION, 32);
    setProperty("FactoryMaxTurboRatio", gMaxTurboRatio, 8);
    registerService();
    IOLog("VoltBarMSR: started\n");
    return true;
}

void VoltBarMSR::stop(IOService *provider) {
    IOLog("VoltBarMSR: stopped\n");
    IOService::stop(provider);
}

// MARK: - User client

class VoltBarMSRUserClient : public IOUserClient {
    OSDeclareDefaultStructors(VoltBarMSRUserClient)
public:
    bool initWithTask(task_t owningTask, void *securityID, UInt32 type) override;
    IOReturn clientClose() override;
    IOReturn externalMethod(uint32_t selector, IOExternalMethodArguments *args,
                            IOExternalMethodDispatch *dispatch, OSObject *target, void *reference) override;

    static IOReturn sRead(OSObject *target, void *ref, IOExternalMethodArguments *args);
    static IOReturn sWrite(OSObject *target, void *ref, IOExternalMethodArguments *args);
    static IOReturn sInfo(OSObject *target, void *ref, IOExternalMethodArguments *args);
};

OSDefineMetaClassAndStructors(VoltBarMSRUserClient, IOUserClient)

static const IOExternalMethodDispatch sMethods[3] = {
    { (IOExternalMethodAction)&VoltBarMSRUserClient::sRead,  1, 0, 1, 0 },
    { (IOExternalMethodAction)&VoltBarMSRUserClient::sWrite, 2, 0, 1, 0 },
    { (IOExternalMethodAction)&VoltBarMSRUserClient::sInfo,  0, 0, 1, 0 },
};

bool VoltBarMSRUserClient::initWithTask(task_t owningTask, void *securityID, UInt32 type) {
    if (clientHasPrivilege(owningTask, kIOClientPrivilegeAdministrator) != kIOReturnSuccess) {
        return false;   // root only
    }
    return IOUserClient::initWithTask(owningTask, securityID, type);
}

IOReturn VoltBarMSRUserClient::clientClose() {
    if (!isInactive()) terminate();
    return kIOReturnSuccess;
}

IOReturn VoltBarMSRUserClient::externalMethod(uint32_t selector, IOExternalMethodArguments *args,
                                              IOExternalMethodDispatch *dispatch, OSObject *target, void *reference) {
    if (selector >= sizeof(sMethods) / sizeof(sMethods[0])) return kIOReturnBadArgument;
    return IOUserClient::externalMethod(selector, args, (IOExternalMethodDispatch *)&sMethods[selector], this, reference);
}

IOReturn VoltBarMSRUserClient::sRead(OSObject *, void *, IOExternalMethodArguments *args) {
    uint64_t v = 0;
    IOReturn r = safeRead((uint32_t)args->scalarInput[0], &v);
    args->scalarOutput[0] = v;
    return r;
}

IOReturn VoltBarMSRUserClient::sWrite(OSObject *, void *, IOExternalMethodArguments *args) {
    uint64_t back = 0;
    IOReturn r = safeWrite((uint32_t)args->scalarInput[0], args->scalarInput[1], &back);
    args->scalarOutput[0] = back;
    return r;
}

IOReturn VoltBarMSRUserClient::sInfo(OSObject *, void *, IOExternalMethodArguments *args) {
    args->scalarOutput[0] = VBMSR_INTERFACE_VERSION;
    return kIOReturnSuccess;
}
