# beacon_chain
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  ../spec/[datatypes, digest, helpers, presets],
  ./block_pools_types, ./blockchain_dag

# State-related functions implemented based on StateData instead of BeaconState

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#get_current_epoch
func get_current_epoch*(stateData: StateData): Epoch =
  ## Return the current epoch.
  getStateField(stateData, slot).epoch

template hash_tree_root*(stateData: StateData): Eth2Digest =
  # Dispatch here based on type/fork of state. Since StateData is a ref object
  # type, if Nim chooses the wrong overload, it will simply fail to compile.
  stateData.data.root
