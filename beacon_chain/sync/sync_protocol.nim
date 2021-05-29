# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  options, tables, sets, macros,
  chronicles, chronos, stew/ranges/bitranges, libp2p/switch,
  ../spec/[datatypes, network, crypto, digest],
  ../beacon_node_types,
  ../networking/eth2_network,
  ../consensus_object_pools/blockchain_dag

logScope:
  topics = "sync"

const
  MAX_REQUEST_BLOCKS = 1024

  blockByRootLookupCost = allowedOpsPerSecondCost(50)
  blockResponseCost = allowedOpsPerSecondCost(100)
  blockByRangeLookupCost = allowedOpsPerSecondCost(20)

type
  StatusMsg* = object
    forkDigest*: ForkDigest
    finalizedRoot*: Eth2Digest
    finalizedEpoch*: Epoch
    headRoot*: Eth2Digest
    headSlot*: Slot

  ValidatorSetDeltaFlags {.pure.} = enum
    Activation = 0
    Exit = 1

  ValidatorChangeLogEntry* = object
    case kind*: ValidatorSetDeltaFlags
    of Activation:
      pubkey: ValidatorPubKey
    else:
      index: uint32

  BeaconBlockCallback* = proc(signedBlock: SignedBeaconBlock) {.gcsafe, raises: [Defect].}

  BeaconSyncNetworkState* = ref object
    chainDag*: ChainDAGRef
    forkDigest*: ForkDigest

  BeaconSyncPeerState* = ref object
    statusLastTime*: chronos.Moment
    statusMsg*: StatusMsg

  BlockRootSlot* = object
    blockRoot: Eth2Digest
    slot: Slot

  BlockRootsList* = List[Eth2Digest, Limit MAX_REQUEST_BLOCKS]

func shortLog*(s: StatusMsg): auto =
  (
    forkDigest: s.forkDigest,
    finalizedRoot: shortLog(s.finalizedRoot),
    finalizedEpoch: shortLog(s.finalizedEpoch),
    headRoot: shortLog(s.headRoot),
    headSlot: shortLog(s.headSlot)
  )
chronicles.formatIt(StatusMsg): shortLog(it)

func disconnectReasonName(reason: uint64): string =
  # haha, nim doesn't support uint64 in `case`!
  if reason == uint64(ClientShutDown): "Client shutdown"
  elif reason == uint64(IrrelevantNetwork): "Irrelevant network"
  elif reason == uint64(FaultOrError): "Fault or error"
  else: "Disconnected (" & $reason & ")"

proc getCurrentStatus*(state: BeaconSyncNetworkState): StatusMsg {.gcsafe.} =
  let
    chainDag = state.chainDag
    headBlock = chainDag.head

  StatusMsg(
    forkDigest: state.forkDigest,
    finalizedRoot:
      getStateField(chainDag.headState, finalized_checkpoint).root,
    finalizedEpoch:
      getStateField(chainDag.headState, finalized_checkpoint).epoch,
    headRoot: headBlock.root,
    headSlot: headBlock.slot)

proc handleStatus(peer: Peer,
                  state: BeaconSyncNetworkState,
                  ourStatus: StatusMsg,
                  theirStatus: StatusMsg): Future[void] {.gcsafe.}

proc setStatusMsg(peer: Peer, statusMsg: StatusMsg) {.gcsafe.}

{.pop.} # TODO fix p2p macro for raises
p2pProtocol BeaconSync(version = 1,
                       networkState = BeaconSyncNetworkState,
                       peerState = BeaconSyncPeerState):

  onPeerConnected do (peer: Peer, incoming: bool) {.async.}:
    debug "Peer connected",
      peer, peerInfo = shortLog(peer.info), incoming
    # Per the eth2 protocol, whoever dials must send a status message when
    # connected for the first time, but because of how libp2p works, there may
    # be a race between incoming and outgoing connections and disconnects that
    # makes the incoming flag unreliable / obsolete by the time we get to
    # this point - instead of making assumptions, we'll just send a status
    # message redundantly.
    # TODO(zah)
    #      the spec does not prohibit sending the extra status message on
    #      incoming connections, but it should not be necessary - this would
    #      need a dedicated flow in libp2p that resolves the race conditions -
    #      this needs more thinking around the ordering of events and the
    #      given incoming flag
    let
      ourStatus = peer.networkState.getCurrentStatus()
      theirStatus = await peer.status(ourStatus, timeout = RESP_TIMEOUT)

    if theirStatus.isOk:
      await peer.handleStatus(peer.networkState,
                              ourStatus, theirStatus.get())
    else:
      debug "Status response not received in time",
            peer, error = theirStatus.error
      await peer.disconnect(FaultOrError)

  proc status(peer: Peer,
              theirStatus: StatusMsg,
              response: SingleChunkResponse[StatusMsg])
    {.async, libp2pProtocol("status", 1).} =
    let ourStatus = peer.networkState.getCurrentStatus()
    trace "Sending status message", peer = peer, status = ourStatus
    await response.send(ourStatus)
    await peer.handleStatus(peer.networkState, ourStatus, theirStatus)

  proc ping(peer: Peer, value: uint64): uint64
    {.libp2pProtocol("ping", 1).} =
    return peer.network.metadata.seq_number

  proc getMetaData(peer: Peer): MetaData
    {.libp2pProtocol("metadata", 1).} =
    return peer.network.metadata

  proc beaconBlocksByRange(
      peer: Peer,
      startSlot: Slot,
      reqCount: uint64,
      reqStep: uint64,
      response: MultipleChunksResponse[SignedBeaconBlock])
      {.async, libp2pProtocol("beacon_blocks_by_range", 1).} =
    trace "got range request", peer, startSlot,
                               count = reqCount, step = reqStep
    if reqCount > 0'u64 and reqStep > 0'u64:
      var blocks: array[MAX_REQUEST_BLOCKS, BlockRef]
      let
        chainDag = peer.networkState.chainDag
        # Limit number of blocks in response
        count = int min(reqCount, blocks.lenu64)

      let
        endIndex = count - 1
        startIndex =
          chainDag.getBlockRange(startSlot, reqStep,
                                 blocks.toOpenArray(0, endIndex))
      peer.updateRequestQuota(
        blockByRangeLookupCost +
        max(0, endIndex - startIndex + 1).float * blockResponseCost)
      peer.awaitNonNegativeRequestQuota()

      for i in startIndex..endIndex:
        doAssert not blocks[i].isNil, "getBlockRange should return non-nil blocks only"
        trace "wrote response block",
          slot = blocks[i].slot, roor = shortLog(blocks[i].root)
        await response.write(chainDag.get(blocks[i]).data)

      debug "Block range request done",
        peer, startSlot, count, reqStep, found = count - startIndex
    else:
      raise newException(InvalidInputsError, "Empty range requested")

  proc beaconBlocksByRoot(
      peer: Peer,
      # Please note that the SSZ list here ensures that the
      # spec constant MAX_REQUEST_BLOCKS is enforced:
      blockRoots: BlockRootsList,
      response: MultipleChunksResponse[SignedBeaconBlock])
      {.async, libp2pProtocol("beacon_blocks_by_root", 1).} =
    if blockRoots.len == 0:
      raise newException(InvalidInputsError, "No blocks requested")

    let
      chainDag = peer.networkState.chainDag
      count = blockRoots.len

    peer.updateRequestQuota(count.float * blockByRootLookupCost)
    peer.awaitNonNegativeRequestQuota()

    var found = 0
    for i in 0..<count:
      let blockRef = chainDag.getRef(blockRoots[i])
      if not isNil(blockRef):
        await response.write(chainDag.get(blockRef).data)
        inc found

    peer.updateRequestQuota(found.float * blockResponseCost)

    debug "Block root request done",
      peer, roots = blockRoots.len, count, found

  proc goodbye(peer: Peer,
               reason: uint64)
    {.async, libp2pProtocol("goodbye", 1).} =
    debug "Received Goodbye message", reason = disconnectReasonName(reason), peer

proc setStatusMsg(peer: Peer, statusMsg: StatusMsg) =
  debug "Peer status", peer, statusMsg
  peer.state(BeaconSync).statusMsg = statusMsg
  peer.state(BeaconSync).statusLastTime = Moment.now()

proc updateStatus*(peer: Peer): Future[bool] {.async.} =
  ## Request `status` of remote peer ``peer``.
  let
    nstate = peer.networkState(BeaconSync)
    ourStatus = getCurrentStatus(nstate)

  let theirFut = awaitne peer.status(ourStatus, timeout = RESP_TIMEOUT)
  if theirFut.failed():
    return false
  else:
    let theirStatus = theirFut.read()
    if theirStatus.isOk:
      peer.setStatusMsg(theirStatus.get)
      return true
    else:
      return false

proc getHeadSlot*(peer: Peer): Slot =
  ## Returns head slot for specific peer ``peer``.
  result = peer.state(BeaconSync).statusMsg.headSlot

proc handleStatus(peer: Peer,
                  state: BeaconSyncNetworkState,
                  ourStatus: StatusMsg,
                  theirStatus: StatusMsg) {.async, gcsafe.} =
  if theirStatus.forkDigest != state.forkDigest:
    debug "Irrelevant peer", peer, theirStatus, ourStatus
    await peer.disconnect(IrrelevantNetwork)
  else:
    peer.setStatusMsg(theirStatus)
    if peer.connectionState == Connecting:
      # As soon as we get here it means that we passed handshake succesfully. So
      # we can add this peer to PeerPool.
      await peer.handlePeer()

proc initBeaconSync*(network: Eth2Node, chainDag: ChainDAGRef,
                     forkDigest: ForkDigest) =
  var networkState = network.protocolState(BeaconSync)
  networkState.chainDag = chainDag
  networkState.forkDigest = forkDigest
