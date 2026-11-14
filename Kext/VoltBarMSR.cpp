// VoltBarMSR — minimal, hardened MSR access driver for VoltBar (replacement for VoltageShift.kext).
// License: GPL-3.0.
//
// Differences from VoltageShift's AnVMSR:
//   * only root (administrator privilege) can open a connection;
//   * reads go through rdmsr_carefully(), so a non-existent MSR returns an error instead of a #GP panic;
//   * writes are allowed only to a small whitelist of registers, and reserved bits are masked off,
//     so a bad value can't trigger a #GP in the kernel;
//   * IA32_MISC_ENABLE (Turbo) is changed on every logical CPU, only bit 38 is touched.
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

#define VBMSR_INTERFACE_VERSION 1

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
    MSR_MISC_ENABLE     = 0x1A0,
    MSR_PKG_POWER_LIMIT = 0x610,
    MSR_PP0_POWER_LIMIT = 0x638,
    MSR_PP1_POWER_LIMIT = 0x640,
};

static const uint64_t TURBO_DISABLE_BIT = 1ULL << 38;

struct TurboArgs { uint64_t bit; volatile SInt32 errors; };

// Runs on every logical CPU with interrupts disabled.
static void turboAction(void *arg) {
    TurboArgs *a = (TurboArgs *)arg;
    uint32_t lo, hi;
    if (rdmsr_carefully(MSR_MISC_ENABLE, &lo, &hi) != 0) { OSIncrementAtomic(&a->errors); return; }
    uint64_t v = ((uint64_t)hi << 32) | lo;
    uint64_t n = (v & ~TURBO_DISABLE_BIT) | a->bit;
    if (n != v) vb_wrmsr(MSR_MISC_ENABLE, n);
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

    case MSR_MISC_ENABLE: {
        TurboArgs a = { value & TURBO_DISABLE_BIT, 0 };
        mp_rendezvous_no_intrs(turboAction, &a);
        if (a.errors) return kIOReturnIOError;
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
    setProperty("InterfaceVersion", VBMSR_INTERFACE_VERSION, 32);
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
