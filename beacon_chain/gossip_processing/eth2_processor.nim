# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  std/tables,
  stew/results,
  chronicles, chronos, metrics,
  ../spec/[crypto, datatypes, digest],
  ../consensus_object_pools/[block_clearance, blockchain_dag, exit_pool, attestation_pool],
  ./gossip_validation, ./gossip_to_consensus,
  ./batch_validation,
  ../validators/validator_pool,
  ../beacon_node_types,
  ../beacon_clock, ../ssz/sszdump

# Metrics for tracking attestation and beacon block loss
declareCounter beacon_attestations_received,
  "Number of beacon chain attestations received by this peer"
declareCounter beacon_aggregates_received,
  "Number of beacon chain aggregate attestations received by this peer"
declareCounter beacon_blocks_received,
  "Number of beacon chain blocks received by this peer"
declareCounter beacon_attester_slashings_received,
  "Number of beacon chain attester slashings received by this peer"
declareCounter beacon_proposer_slashings_received,
  "Number of beacon chain proposer slashings received by this peer"
declareCounter beacon_voluntary_exits_received,
  "Number of beacon chain voluntary exits received by this peer"

const delayBuckets = [2.0, 4.0, 6.0, 8.0, 10.0, 12.0, 14.0, Inf]

declareHistogram beacon_attestation_delay,
  "Time(s) between slot start and attestation reception", buckets = delayBuckets

declareHistogram beacon_aggregate_delay,
  "Time(s) between slot start and aggregate reception", buckets = delayBuckets

declareHistogram beacon_block_delay,
  "Time(s) between slot start and beacon block reception", buckets = delayBuckets

type
  Eth2Processor* = object
    doppelGangerDetectionEnabled*: bool
    getWallTime*: GetWallTimeFn

    # Local sources of truth for validation
    # ----------------------------------------------------------------
    chainDag*: ChainDAGRef
    attestationPool*: ref AttestationPool
    validatorPool: ref ValidatorPool

    doppelgangerDetection*: DoppelgangerProtection

    # Gossip validated -> enqueue for further verification
    # ----------------------------------------------------------------
    verifQueues: ref VerifQueueManager

    # Validated with no further verification required
    # ----------------------------------------------------------------
    exitPool: ref ExitPool

    # Almost validated, pending cryptographic signature check
    # ----------------------------------------------------------------
    batchCrypto*: ref BatchCrypto

    # Missing information
    # ----------------------------------------------------------------
    quarantine*: QuarantineRef

# Initialization
# ------------------------------------------------------------------------------

proc new*(T: type Eth2Processor,
          doppelGangerDetectionEnabled: bool,
          verifQueues: ref VerifQueueManager,
          chainDag: ChainDAGRef,
          attestationPool: ref AttestationPool,
          exitPool: ref ExitPool,
          validatorPool: ref ValidatorPool,
          quarantine: QuarantineRef,
          rng: ref BrHmacDrbgContext,
          getWallTime: GetWallTimeFn): ref Eth2Processor =
  (ref Eth2Processor)(
    doppelGangerDetectionEnabled: doppelGangerDetectionEnabled,
    getWallTime: getWallTime,
    verifQueues: verifQueues,
    chainDag: chainDag,
    attestationPool: attestationPool,
    exitPool: exitPool,
    validatorPool: validatorPool,
    quarantine: quarantine,
    batchCrypto: BatchCrypto.new(
      rng = rng,
      # Only run eager attestation signature verification if we're not
      # processing blocks in order to give priority to block processing
      eager = proc(): bool = not verifQueues[].hasBlocks())
  )

# Gossip Management
# -----------------------------------------------------------------------------------

proc blockValidator*(
    self: var Eth2Processor,
    signedBlock: SignedBeaconBlock): ValidationResult =
  logScope:
    signedBlock = shortLog(signedBlock.message)
    blockRoot = shortLog(signedBlock.root)

  let
    wallTime = self.getWallTime()
    (afterGenesis, wallSlot) = wallTime.toSlot()

  if not afterGenesis:
    return ValidationResult.Ignore  # not an issue with block, so don't penalize

  logScope: wallSlot

  let delay = wallTime - signedBlock.message.slot.toBeaconTime

  if signedBlock.root in self.chainDag:
    # The gossip algorithm itself already does one round of hashing to find
    # already-seen data, but it is fairly aggressive about forgetting about
    # what it has seen already
    debug "Dropping already-seen gossip block", delay
    return ValidationResult.Ignore  # "[IGNORE] The block is the first block ..."

  # Start of block processing - in reality, we have already gone through SSZ
  # decoding at this stage, which may be significant
  debug "Block received", delay

  let blck = self.chainDag.isValidBeaconBlock(
    self.quarantine, signedBlock, wallTime, {})

  self.verifQueues[].dumpBlock(signedBlock, blck)

  if not blck.isOk:
    return blck.error[0]

  beacon_blocks_received.inc()
  beacon_block_delay.observe(delay.toFloatSeconds())

  # Block passed validation - enqueue it for processing. The block processing
  # queue is effectively unbounded as we use a freestanding task to enqueue
  # the block - this is done so that when blocks arrive concurrently with
  # sync, we don't lose the gossip blocks, but also don't block the gossip
  # propagation of seemingly good blocks
  trace "Block validated"
  self.verifQueues[].addBlock(SyncBlock(blk: signedBlock))

  ValidationResult.Accept

proc checkForPotentialDoppelganger(
    self: var Eth2Processor, attestationData: AttestationData,
    attesterIndices: openArray[ValidatorIndex], wallSlot: Slot) =
  let epoch = wallSlot.epoch

  # Only check for current epoch, not potential attestations bouncing around
  # from up to several minutes prior.
  if attestationData.slot.epoch < epoch:
    return

  if epoch < self.doppelgangerDetection.broadcastStartEpoch:
    let tgtBlck = self.chainDag.getRef(attestationData.target.root)
    doAssert not tgtBlck.isNil  # because attestation is valid above

    let epochRef = self.chainDag.getEpochRef(
      tgtBlck, attestationData.target.epoch)
    for validatorIndex in attesterIndices:
      let validatorPubkey = epochRef.validator_keys[validatorIndex]
      if  self.doppelgangerDetectionEnabled and
          self.validatorPool[].getValidator(validatorPubkey) !=
            default(AttachedValidator):
        warn "We believe you are currently running another instance of the same validator. We've disconnected you from the network as this presents a significant slashing risk. Possible next steps are (a) making sure you've disconnected your validator from your old machine before restarting the client; and (b) running the client again with the gossip-slashing-protection option disabled, only if you are absolutely sure this is the only instance of your validator running, and reporting the issue at https://github.com/status-im/nimbus-eth2/issues.",
          validatorIndex,
          validatorPubkey,
          attestationSlot = attestationData.slot
        quit QuitFailure

{.pop.} # async can raise anything

proc attestationValidator*(
    self: ref Eth2Processor,
    attestation: Attestation,
    subnet_id: SubnetId,
    checkSignature: bool = true): Future[ValidationResult] {.async.} =
  logScope:
    attestation = shortLog(attestation)
    subnet_id

  let
    wallTime = self.getWallTime()
    (afterGenesis, wallSlot) = wallTime.toSlot()

  if not afterGenesis:
    notice "Attestation before genesis"
    return ValidationResult.Ignore

  logScope: wallSlot

  # Potential under/overflows are fine; would just create odd metrics and logs
  let delay = wallTime - attestation.data.slot.toBeaconTime
  debug "Attestation received", delay

  # Now proceed to validation
  let v = await self.attestationPool.validateAttestation(
      self.batchCrypto, attestation, wallTime, subnet_id, checkSignature)
  if v.isErr():
    debug "Dropping attestation", err = v.error()
    return v.error[0]

  beacon_attestations_received.inc()
  beacon_attestation_delay.observe(delay.toFloatSeconds())

  let (attestation_index, sig) = v.get()

  self[].checkForPotentialDoppelganger(
    attestation.data, [attestation_index], wallSlot)

  trace "Attestation validated"
  self.attestationPool[].addAttestation(
    attestation, [attestation_index], sig, wallSlot)

  return ValidationResult.Accept

proc aggregateValidator*(
    self: ref Eth2Processor,
    signedAggregateAndProof: SignedAggregateAndProof): Future[ValidationResult] {.async.} =
  logScope:
    aggregate = shortLog(signedAggregateAndProof.message.aggregate)
    signature = shortLog(signedAggregateAndProof.signature)

  let
    wallTime = self.getWallTime()
    (afterGenesis, wallSlot) = wallTime.toSlot()

  if not afterGenesis:
    notice "Aggregate before genesis"
    return ValidationResult.Ignore

  logScope: wallSlot

  # Potential under/overflows are fine; would just create odd logs
  let delay =
    wallTime - signedAggregateAndProof.message.aggregate.data.slot.toBeaconTime
  debug "Aggregate received", delay

  let v = await self.attestationPool.validateAggregate(
      self.batchCrypto,
      signedAggregateAndProof, wallTime)
  if v.isErr:
    debug "Dropping aggregate",
      err = v.error,
      aggregator_index = signedAggregateAndProof.message.aggregator_index,
      selection_proof = signedAggregateAndProof.message.selection_proof,
      wallSlot
    return v.error[0]

  beacon_aggregates_received.inc()
  beacon_aggregate_delay.observe(delay.toFloatSeconds())

  let (attesting_indices, sig) = v.get()

  self[].checkForPotentialDoppelganger(
    signedAggregateAndProof.message.aggregate.data, attesting_indices,
    wallSlot)

  trace "Aggregate validated",
    aggregator_index = signedAggregateAndProof.message.aggregator_index,
    selection_proof = signedAggregateAndProof.message.selection_proof,
    wallSlot

  self.attestationPool[].addAttestation(
    signedAggregateAndProof.message.aggregate, attesting_indices, sig, wallSlot)

  return ValidationResult.Accept

proc attesterSlashingValidator*(
    self: var Eth2Processor, attesterSlashing: AttesterSlashing):
    ValidationResult =
  logScope:
    attesterSlashing = shortLog(attesterSlashing)

  let v = self.exitPool[].validateAttesterSlashing(attesterSlashing)
  if v.isErr:
    debug "Dropping attester slashing", err = v.error
    return v.error[0]

  beacon_attester_slashings_received.inc()

  ValidationResult.Accept

proc proposerSlashingValidator*(
    self: var Eth2Processor, proposerSlashing: ProposerSlashing):
    ValidationResult =
  logScope:
    proposerSlashing = shortLog(proposerSlashing)

  let v = self.exitPool[].validateProposerSlashing(proposerSlashing)
  if v.isErr:
    debug "Dropping proposer slashing", err = v.error
    return v.error[0]

  beacon_proposer_slashings_received.inc()

  ValidationResult.Accept

proc voluntaryExitValidator*(
    self: var Eth2Processor, signedVoluntaryExit: SignedVoluntaryExit):
    ValidationResult =
  logScope:
    signedVoluntaryExit = shortLog(signedVoluntaryExit)

  let v = self.exitPool[].validateVoluntaryExit(signedVoluntaryExit)
  if v.isErr:
    debug "Dropping voluntary exit", err = v.error
    return v.error[0]

  beacon_voluntary_exits_received.inc()

  ValidationResult.Accept
