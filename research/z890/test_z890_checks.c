/* Z890 profile: the shared checks against this machine's own capture (DIAG02.TXT), and refusals around it. GPL-2.0-only. */
#include "checks.h"
#include <stdio.h>
#include <string.h>

static unsigned Checks, Failures;
static void Check(int Pass, const char *Name) {
  ++Checks;
  if (!Pass) { ++Failures; fprintf(stderr, "FAIL %s\n", Name); }
}
static const UINT32 Config[64] = {0x220410de,0x00100003,0x030000a1,0x00800010,0x8d000000,0x0000000c,0x000000a0,0x0000000c,0x000000a8,0x00009001,0x00000000,0x38801028,0x8e000000,0x00000060,0x00000000,0x000001ff,0x38801028,0x00000000,0x00000000,0x00000000,0x00000000,0x00000001,0x0023d6ce,0x00000000,0x48036801,0x00000008,0x00807805,0x00000000,0x00000000,0x00000000,0x0012b410,0x112c8de1,0x00092930,0x00454d04,0x11040140,0x00000000,0x00000000,0x00000000,0x00000000,0x00070813,0x00001400,0x0180001e,0x001e0004,0x00000000,0x00000000,0x01140009,0x00000000,0x00000000,0x00000000,0x00000000,0x00050011,0x00b90000,0x00ba0000,0x00000000,0x00000000,0x00000000,0x00000000,0x00000000,0x00000000,0x00000000,0x00000000,0x00000000,0x00000000,0x00000000};
/* PciRoot(0)/Pci(2,0)/ADR 0x80013341: the Intel GOP as captured. */
static const UINT8 Intel[] = {2,1,12,0,0xd0,0x41,3,10,0,0,0,0, 1,1,6,0,0,2, 2,3,8,0,0x41,0x33,1,0x80, 0x7f,0xff,4,0};
/* The B650M's AMD GOP route, the RTX's route, and the Intel GOP on another display address. */
static const UINT8 Amd[] = {2,1,12,0,0xd0,0x41,3,10,0,0,0,0, 1,1,6,0,1,8, 1,1,6,0,0,0, 2,3,8,0,0,3,1,0x80, 0x7f,0xff,4,0};
static const UINT8 OtherAdr[] = {2,1,12,0,0xd0,0x41,3,10,0,0,0,0, 1,1,6,0,0,2, 2,3,8,0,0x42,0x33,1,0x80, 0x7f,0xff,4,0};
static const UINT8 OtherDevice[] = {2,1,12,0,0xd0,0x41,3,10,0,0,0,0, 1,1,6,0,0,3, 2,3,8,0,0x41,0x33,1,0x80, 0x7f,0xff,4,0};
static const UINT8 Rtx[] = {2,1,12,0,0xd0,0x41,3,10,0,0,0,0, 1,1,6,0,0,6, 1,1,6,0,0,0, 0x7f,0xff,4,0};
#define PATH(p) ((const EFI_DEVICE_PATH_PROTOCOL *)(p))

int main(void) {
  GU_CAPS Caps;
  UINT32 C[64];
  Check(GuCheckConfig(Config, 0, 2, 0, 0, &Caps), "captured config accepted");
  printf("caps pm=%#x pcie=%#x msi=%#x msix=%#x\n", Caps.pm, Caps.pcie, Caps.msi, Caps.msix);
  Check(Caps.pm == 0x60 && Caps.pcie == 0x78 && Caps.msi == 0x68, "capability offsets as captured");
  Check(!GuCheckConfig(Config, 0, 1, 0, 0, &Caps), "another bus refused");
  Check(!GuCheckConfig(Config, 0, 2, 1, 0, &Caps), "another device refused");
  memcpy(C, Config, sizeof(C)); C[11] = 0x145410de;
  Check(!GuCheckConfig(C, 0, 2, 0, 0, &Caps), "another subsystem refused");
  memcpy(C, Config, sizeof(C)); C[0] = 0x220310de;
  Check(!GuCheckConfig(C, 0, 2, 0, 0, &Caps), "another card refused");
  memcpy(C, Config, sizeof(C)); C[1] |= 4;
  Check(!GuCheckConfig(C, 0, 2, 0, 0, &Caps), "bus mastering on refused");
  memcpy(C, Config, sizeof(C)); C[1] &= ~2U;
  Check(!GuCheckConfig(C, 0, 2, 0, 0, &Caps), "memory decode off refused");
  Check(GuDisplayPath(PATH(Intel), sizeof(Intel)) == 1, "captured Intel GOP is the display");
  Check(GuDisplayPath(PATH(Amd), sizeof(Amd)) != 1, "AMD route is not the display here");
  Check(GuDisplayPath(PATH(OtherAdr), sizeof(OtherAdr)) != 1, "other display address refused");
  Check(GuDisplayPath(PATH(OtherDevice), sizeof(OtherDevice)) != 1, "other PCI device refused");
  Check(GuDisplayPath(PATH(Rtx), sizeof(Rtx)) != 1, "the RTX is never the display");
  printf("%u checks, %u failures\n", Checks, Failures);
  return Failures != 0;
}
