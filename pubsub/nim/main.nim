import serialization, json_serialization, stew/endians2, stew/byteutils
import libp2p, testground_sdk, libp2p/protocols/pubsub/rpc/messages
import chronos
import sequtils, hashes
from times import getTime, toUnix, fromUnix, `-`, initTime, `$`, inMilliseconds

type
  PeerData = object
    id {.serializedFieldName: "ID".}: string
    addrs {.serializedFieldName: "Addrs".}: seq[string]

proc msgIdProvider(m: Message): Result[MessageID, ValidationResult] =
  return ok(($m.data.hash).toBytes())

testground(client):
  let addresses = getInterfaces().filterIt(it.name == "eth1").mapIt(it.addresses)
  if addresses.len < 1 or addresses[0].len < 1:
    quit "Can't find local ip!"

  let peersTopic = client.subscribe("peers", PeerData)

  let
    myId = await client.signal("initialized_global")
    isPublisher = myId <= client.param(int, "publisher_count")
    isAttacker = myId - client.param(int, "publisher_count") <= client.param(int, "attacker_count")
    rng = libp2p.newRng()
    address = addresses[0][0].host
    switch =
      SwitchBuilder
        .new()
        .withAddress(MultiAddress.init(address).tryGet())
        .withRng(rng)
        .withYamux()
        #.withMplex()
        .withTcpTransport(flags = {ServerFlags.TcpNoDelay})
        #.withPlainText()
        .withNoise()
        .build()
    gossipSub = GossipSub.init(
      switch = switch,
      triggerSelf = true,
      msgIdProvider = msgIdProvider,
      verifySignature = false,
      anonymize = true,
      )
  gossipSub.parameters.floodPublish = false
  gossipSub.parameters.opportunisticGraftThreshold = 10000
  gossipSub.parameters.heartbeatInterval = 500.milliseconds
  gossipSub.parameters.pruneBackoff = 5.seconds
  gossipSub.topicParams["test"] = TopicParams(
    topicWeight: 1,
    firstMessageDeliveriesWeight: 1,
    firstMessageDeliveriesCap: 30,
    firstMessageDeliveriesDecay: 0.6
  )

  proc messageHandler(topic: string, data: seq[byte]) {.async.} =
    let sentUint = uint64.fromBytesLE(data)
    # warm-up
    if sentUint < 1000000 or isAttacker: return
    let
      sentMoment = nanoseconds(int64(uint64.fromBytesLE(data)))
      sentNanosecs = nanoseconds(sentMoment - seconds(sentMoment.seconds))
      sentDate = initTime(sentMoment.seconds, sentNanosecs)
      diff = getTime() - sentDate
    echo sentUint, " milliseconds: ", diff.inMilliseconds()


  var receivedMessage = 0
  proc messageValidator(topic: string, msg: Message): Future[ValidationResult] {.async.} =
    receivedMessage.inc()
    return
      if receivedMessage >= client.param(int, "attack_after"):
        ValidationResult.Ignore
      else:
        ValidationResult.Accept
  gossipSub.subscribe("test", messageHandler)
  if isAttacker:
    gossipSub.addValidator(["test"], messageValidator)
  switch.mount(gossipSub)
  await switch.start()
  #TODO
  #defer: await switch.stop()

  await client.publish("peers",
    PeerData(
      id: $switch.peerInfo.peerId,
      addrs: switch.peerInfo.addrs.mapIt($it)
    )
  )
  echo "Listening on ", switch.peerInfo.addrs
  echo myId, ", ", isPublisher, ", ", switch.peerInfo.peerId

  var peersInfo: seq[PeerData]
  while peersInfo.len < client.testInstanceCount:
    peersInfo.add(await peersTopic.popFirst())

  rng.shuffle(peersInfo)

  let connectTo = client.param(int, "connection_count")
  var connected = 0
  for peerInfo in peersInfo:
    if peerInfo.id == $switch.peerInfo.peerId: continue

    if connected >= connectTo: break
    let
      peerId = PeerId.init(peerInfo.id).tryGet()
      addrs = peerInfo.addrs.mapIt(MultiAddress.init(it).tryGet())
    try:
      await switch.connect(peerId, addrs)
      connected.inc()
    except CatchableError as exc:
      echo "Failed to dial", exc.msg

  await client.updateNetworkParameter(
    NetworkConf(
      network: "default",
      enable: true,
      callback_state: "connected",
      callback_target: some client.testInstanceCount,
      routing_policy: "accept_all",
      default: LinkShape(
        latency: 100000000,
      #  jitter: 100000000,
      )

    )
  )

  await client.waitForBarrier("connected", client.testInstanceCount)

  if isPublisher:
    # wait for mesh to be setup
    let maxMessageDelay = client.param(int, "max_message_delay")
    for i in 0 ..< client.param(int, "warmup_messages"):
      await sleepAsync(milliseconds(rng.rand(maxMessageDelay)))
      doAssert((await gossipSub.publish("test", @(toBytesLE(uint64(myId * 1000 + i))))) > 0)

    for _ in 0 ..< client.param(int, "message_count"):
      await sleepAsync(milliseconds(rng.rand(maxMessageDelay)))
      let
        now = getTime()
        nowInt = seconds(now.toUnix()) + nanoseconds(times.nanosecond(now))
        nowBytes = @(toBytesLE(uint64(nowInt.nanoseconds)))
      #echo "sending ", uint64(nowInt.nanoseconds)
      doAssert((await gossipSub.publish("test", nowBytes)) > 0)

  discard await client.signalAndWait("done", client.testInstanceCount)
