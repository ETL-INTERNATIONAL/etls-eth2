# beacon_chain
# Copyright (c) 2018-2020 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

const GccCompatible = defined(gcc) or defined(clang)
const x86arch = defined(i386) or defined(amd64)

const supports_x86_inline_asm = block:
  x86arch and (
    (
      GccCompatible and not defined(windows)
    ) or (
      defined(vcc)
    )
  )

when supports_x86_inline_asm:
  import x86
  export getTicks, cpuName

  const SupportsCPUName* = true
  const SupportsGetTicks* = true
else:
  const SupportsCPUName* = false
  const SupportsGetTicks* = false
