# Raft

Adjoint's implementation of the Raft consensus algorithm. See [original
paper](https://ramcloud.stanford.edu/wiki/download/attachments/11370504/raft.pdf)
for further details about the protocol.

# Overview and main contributions

Raft proposes a strong single-leader approach to consensus. It simplifies
operations, as there are no conflicts, while being more efficient than other
leader-less approaches due to the high throughput acheivable by the leader. In
this leader-driven consensus algorithm, clients must contact the leader directly
in order to communicate with the system. The system needs to have an
elected leader in order to be available.

In addition to a pure core event loop, this library uses the systematic
concurrency testing library
[dejafu](https://hackage.haskell.org/package/dejafu-1.11.0.3) to test
certain properties about streams of events throughout the system. Random thread
interleavings are generated in a raft network and realistic event
streams are delivered to each node's event queue. We test for the absence of
deadlocks and exceptions, along with checking that the convergent state of the
system matches the expected results. These concurrency tests can be found
[here](https://github.com/adjoint-io/raft/blob/master/test/TestDejaFu.hs).

## Ensuring valid transitions between node states

Each server in Raft can only be in one of these three states:

- Leader: Active node that handles all client interactions and send
  AppendEntries RPCs to all other nodes.
- Candidate: Active node that attempts to become a leader.
- Follower: Passive node that just responds to RPCs.

Temporal (e.g. ElectionTimeout) and spatial (e.g. AppendEntries or RequestVote)
events cause nodes to transition from one state to another.

```
    [0]                     [1]                       [2]
------------> Follower --------------> Candidate --------------> Leader
               ^  ^                       |                        |
               |  |         [3]           |                        |
               |  |_______________________|                        |
               |                                                   |
               |                                 [4]               |
               |___________________________________________________|

- [0] Starts up | Recovers
- [1] Times out | Starts election
- [2] Receives votes from majority of servers and becomes leader
- [3] Discovers leader of new term | Discovers candidate with a higher term
- [4] Discovers server with higher term
```

All nodes in the Raft protocol begin in the follower state. A follower will stay
a follower unless it fails to hear from a leader or a candidate requesting a
vote within its ElectionTimeout timer. If this happens, a follower will
transition to a candidate state. These node states are illustrated in the type:

```haskell
data Mode
  = Follower
  | Candidate
  | Leader
```

The volatile state a node keeps track of may vary depending on the mode that it
is in. Using `DataKinds` and `GADTs`, we relate these specific node state
datatypes that contain the relevant data to the current node's mode with the
`NodeState` type. This way, we can enforce that the volatile state carried by a
node in mode `Follower` is indeed `FollowerState`, etc:

```haskell
-- | The volatile state of a Raft Node
data NodeState (a :: Mode) where
  NodeFollowerState :: FollowerState -> NodeState 'Follower
  NodeCandidateState :: CandidateState -> NodeState 'Candidate
  NodeLeaderState :: LeaderState -> NodeState 'Leader
```

The library's main event loop is comprised of a simple flow: Raft nodes receive
events on an STM channel, handle the event depending on the current node state,
return a list of actions to perform, and then perform those actions in the order
they were generated. The `Event` type specificies the main value to which raft
nodes react to, whereas the `Action` type specifies the action the raft node
performs as a result of the pairing of the current node state and received
event.

The Raft protocol has constraints on how nodes transition from one state to
another. For example, a follower cannot transition to a leader state
without first transitioning to a candidate state. Similarly, a leader can
never transition directly to a candidate state due to the algorithm
specification. Candidates are allowed to transition to any other node state.

To adhere to the Raft specification, we make use of some type level programming
to ensure that only valid transitions happen between node states.

```haskell
-- | All valid state transitions of a Raft node
data Transition (init :: Mode) (res :: Mode) where
  StartElection            :: Transition 'Follower 'Candidate
  HigherTermFoundFollower  :: Transition 'Follower 'Follower

  RestartElection          :: Transition 'Candidate 'Candidate
  DiscoverLeader           :: Transition 'Candidate 'Follower
  HigherTermFoundCandidate :: Transition 'Candidate 'Follower
  BecomeLeader             :: Transition 'Candidate 'Leader

  SendHeartbeat            :: Transition 'Leader 'Leader
  DiscoverNewLeader        :: Transition 'Leader 'Follower
  HigherTermFoundLeader    :: Transition 'Leader 'Follower

  Noop :: Transition init init
```

To compose the `Transition` with the resulting state from the event handler, we
use the `ResultState` datatype, existentially quantifying the result state mode:

```haskell
-- | Existential type hiding the result type of a transition, fixing the
-- result state to the state dictated by the 'Transition init res' value.
data ResultState init v where
  ResultState :: Transition init res -> NodeState res -> ResultState init
```

This datatype fixes the result state to be dependent on the transition that
occurred; as long as the allowed transitions are correctly denoted in the
`Transition` data constructors, only valid transitions can be specified by the
`ResultState`. Furthermore, `ResultState` values existentially hide the result
state types, that can be accessed via pattern matching. Thus, all event
handlers, be they RPC handlers, timeout handlers, or client request handlers,
have a type signature of the form:

```haskell
handler :: NodeState init -> ... relevant handler data ... -> ResultState init
```

Statically, the `ResultState` will enforce that invalid transitions are not made
when writing handlers for all combinations of raft node modes and events. In the
future, this approach may be extended to limit the actions a node can emit
dependent on it's current mode.

## Library Architecture

Within the Raft protocol, there is a pure core that can be abstracted without
the use of global state. The protocol can be looked at simply as a series
of function calls of a function from an initial node state to a result node
state. However, sometimes these transitions have *side effects*. In this library
we have elected to separate the *pure* and **effectful** layers.

The core event handling loop is a *pure* function that, given the current node
state and a few extra bits of global state, computes a list of `Action`s for the
effectful layer to perform (updating global state, sending a message to another
node over the network, etc.).

### Pure Layer

In order to update the replicated state machine, clients contact the leader via
"client requests" containing commands to be committed to the replicated state
machine. Once a command is received, the current leader assesses whether it is
possible to commit the command to the replicated state machine.

The replicated state machine must be deterministic such that every command
committed by a leader to the state machine will eventually be replicated on
every node in the network at the same index.

As the only part of the internal event loop that needs to be specified manually,
We ask users of our library to provide an instance of the `StateMachine`
typeclass. This typeclass relates a state machine type to a command type
and a single type class function 'applyCommittedLogEntry', a pure function that
should return the result of applying the command to the initial state machine.

```haskell
class StateMachine sm v | sm -> v where
  applyCommittedLogEntry :: sm -> v -> sm
```

Everything else related to the core event handling loop is not exposed to
library users. All that needs to be specified is the type of the state machine,
the commands to update it, and how to perform those updates.

### Effectful Layers

In the protocol, there are two main components that need access to global
state and system resources. Firstly, raft nodes must maintain some persistent
state for efficient and correct recovery from network outages or partitions.
Secondly, raft nodes need to send messages to other raft nodes for the network
(the replicated state machine) to be operational.

#### Persistent State

Each node persists data to disk, including the replicated log
entries. Since persisting data is an action that programmers have many opinions
and preferences regarding, we provide two type classes that abstract the
specifics of writing log entries to disk as well as a few other small bits of
relevant data. These are separated due to the nature in which the log entries
are queried, often by specific index and without bounds. Thus it may be
desirable to store the log entries in an efficient database. The remaining
persistent data is always read and written atomically, and has a much smaller
storage footprint.

The actions of reading or modifying existing log entries on disk is broken down
even further: we ask the user to specify how to write, delete, and read
log entries from disk. Often these types of operations can be optimized via
smarter persistent data solutions like modern SQL databases, thus we arrive at
the following level of granularity:

```haskell
-- | The type class specifying how nodes should write log entries to storage.
class Monad m => RaftWriteLog m v where
  type RaftWriteLogError m
  -- | Write the given log entries to storage
  writeLogEntries
    :: Exception (RaftWriteLogError m)
    => Entries v -> m (Either (RaftWriteLogError m) ())

-- | The type class specifying how nodes should delete log entries from storage.
class Monad m => RaftDeleteLog m v where
  type RaftDeleteLogError m
  -- | Delete log entries from a given index; e.g. 'deleteLogEntriesFrom 7'
  -- should delete every log entry
  deleteLogEntriesFrom
    :: Exception (RaftDeleteLogError m)
    => Index -> m (Either (RaftDeleteLogError m) (Maybe (Entry v)))

-- | The type class specifying how nodes should read log entries from storage.
class Monad m => RaftReadLog m v where
  type RaftReadLogError m
  -- | Read the log at a given index
  readLogEntry
    :: Exception (RaftReadLogError m)
    => Index -> m (Either (RaftReadLogError m) (Maybe (Entry v)))
  -- | Read log entries from a specific index onwards
  readLogEntriesFrom
    :: Exception (RaftReadLogError m)
    => Index -> m (Either (RaftReadLogError m) (Entries v))
  -- | Read the last log entry in the log
  readLastLogEntry
    :: Exception (RaftReadLogError m)
    => m (Either (RaftReadLogError m) (Maybe (Entry v)))
```

To read and write the `PersistentData` type (the remaining persistent data that
is not log entries), we ask the user to use the following `RaftPersist`
typeclass.

```haskell
-- | The RaftPersist type class specifies how to read and write the persistent
-- state to disk.
--
class Monad m => RaftPersist m where
  type RaftPersistError m
  readPersistentState
    :: Exception (RaftPersistError m)
    => m (Either (RaftPersistError m) PersistentState)
  writePersistentState
    :: Exception (RaftPersistError m)
    => PersistentState -> m (Either (RaftPersistError m) ())
```

### Networking

The other non-deterministic, effectful part of the protocol is the communication
between nodes over the network. It can be unreliable due to network delays,
partitions and packet loss, duplication and reordering, but the Raft consensus
algorithm was designed to achieve consensus in such harsh conditions.

The actions that must be performed in the networking layer are *sending RPCs* to
other raft nodes, *receiving RPCs* from other raft nodes, *sending client
responses* to clients who have issued requests, and *receiving client requests*
from clients wishing to update the replicated state. Depending on use of this
raft library, the two pairs are not necessary symmetric and so we do not
force the user into specifying a single way to send/receive messages to and from
raft nodes or clients.

We provide several type classes for users to specify the networking layer
themselves. The user must make sure that the `sendRPC`/`receiveRPC` and
`sendClient`/`receiveClient` pairs perform complementary actions; that an RPC
sent from one raft node to another is indeed receivable via `receiveRPC` on the
node to which it was sent:

```haskell
-- | Provide an interface for nodes to send messages to one
-- another. E.g. Control.Concurrent.Chan, Network.Socket, etc.
class RaftSendRPC m v where
  sendRPC :: NodeId -> RPCMessage v -> m ()

-- | Provide an interface for nodes to receive messages from one
-- another
class RaftRecvRPC m v where
  receiveRPC :: m (RPCMessage v)

-- | Provide an interface for Raft nodes to send messages to clients
class RaftSendClient m sm where
  sendClient :: ClientId -> ClientResponse sm -> m ()

-- | Provide an interface for Raft nodes to receive messages from clients
class RaftRecvClient m v where
  receiveClient :: m (ClientRequest v)
```

We have written a default implementation for network sockets over TCP in
[src/Examples/Raft/Socket](https://github.com/adjoint-io/raft/blob/master/src/Examples/Raft/Socket)

# Run example

We provide a complete example of the library where nodes communicate via network
sockets and they write their logs on text files. See
[app/Main.hs](https://github.com/adjoint-io/raft/blob/master/app/Main.hs) to
have further insight.

1) Build the example executable:
```$ stack build ```

2) In separate terminals, run some raft nodes:

    The format of the cmd line invocation is:
    ``` raft-example <node-id> <peer-1-node-id> ... <peer-n-node-id> ```

    We are going to run a network of three nodes:

    - On terminal 1:
    ```$ stack exec raft-example localhost:3001 localhost:3002 localhost:3003```

    - On terminal 2:
    ```$ stack exec raft-example localhost:3002 localhost:3001 localhost:3003```

    - On terminal 3:
    ```$ stack exec raft-example localhost:3003 localhost:3001 localhost:3002```

    The first node spawned should become candidate once its election's timer
    times out and request votes to other nodes. It will then become the leader,
    once it receives a majority of votes and will broadcast messages to all
    nodes at each heartbeat.

3) Run a client:
```$ stack exec raft-example client```

    In the example provided, there are five basic operations:

      - `addNode <host:port>`: Add a nodeId to the set of nodeIds that the client
        will communicate with. Adding a single node will be sufficient, as this node
        will redirect the command to the leader in case he is not.

      - `getNodes`: Return all node ids that the client is aware of.

      - `read`: Return the state of the leader.

      - `set <var> <val>`: Set a variable to a specific value.

      - `incr <var>`: Increment the value of a variable.

    Assuming that two nodes are run as mentioned above, a valid client workflow
    would be:
    ```
    >>> addNode localhost:3001
    >>> set testVar 4
    >>> incr testVar
    >>> read
    ```

    It will return the state of the leader's state machine (and eventually the state
    of all nodes in the Raft network). In our example, it will be a map of a single
    key `testVar` of value `4`

## How to use this library

1. [Define the state
machine](https://github.com/adjoint-io/raft#define-the-state-machine)
2. [Implement the networking
layer](https://github.com/adjoint-io/raft#implement-the-networking-layer)
3. [Implement the persistent
layer](https://github.com/adjoint-io/raft#implement-the-persistent-layer)
4. [Wrapping it
   together](https://github.com/adjoint-io/raft#wrapping-it-together)

### Define the state machine

The only requirement for our state machine is to instantiate the `StateMachine`
type class.

```haskell
class StateMachine sm v | sm -> v where
  applyCommittedLogEntry :: sm -> v -> sm
```

In our [example](https://github.com/adjoint-io/raft/blob/master/app/Main.hs) we
use a simple map as a store whose values can only increase.

### Implement the networking layer

We leave the choice of the networking layer open to the user, as it can vary
depending on the use case (E.g. TCP/UDP/cloud-haskell/etc).

We need to specify how nodes will communicate with clients and with each other.
As described above in the [Networking
section](https://github.com/adjoint-io/raft#networking), it suffices to
implement those four type classes (`RaftSendRPC`, `RaftRecvRPC`,
`RaftSendClient`, `RaftRecvClient`).

In our example, we provide instances of nodes communicating over TCP to other
nodes
([Socket/Node.hs](https://github.com/adjoint-io/raft/blob/documentation/src/Examples/Raft/Socket/Node.hs))
and clients
([Socket/Client.hs](https://github.com/adjoint-io/raft/blob/documentation/src/Examples/Raft/Socket/Client.hs)).

Note that our datatypes will need to derive instances of `MonadThrow`,
`MonadCatch`, `MonadMask` and `MonadConc`. This allows us to test concurrent
properties of the system, using randomized thread scheduling to assert the
absence of deadlocks and exceptions.

In case of the `RaftSocketT` data type used in our example:

```haskell
deriving instance MonadConc m => MonadThrow (RaftSocketT v m)
deriving instance MonadConc m => MonadCatch (RaftSocketT v m)
deriving instance MonadConc m => MonadMask (RaftSocketT v m)
deriving instance MonadConc m => MonadConc (RaftSocketT v m)
```

### Implement the persistent layer

There are many different possibilities when it comes to persist data to disk, so
we also leave the specification open to the user.

As explained in the [Persistent
State](https://github.com/adjoint-io/raft#persistent-state) section above, we
will create instances for `RaftReadLog`, `RaftWriteLog` and
`RaftDeleteLog` to specify how we will read, write and
delete log entries, as well as `RaftPersist`.

We provide an implementation that stores persistent data on files in
[FileStore.hs](https://github.com/adjoint-io/raft/blob/master/src/Examples/Raft/FileStore.hs)

### Wrapping it together

The last step is wrapping our previous data types that deal with
networking and persistent data into a single monad that also derives instances
of all the Raft type classes described (`RaftSendRPC`, `RaftRecvRPC`,
`RaftSendClient`, `RaftRecvClient`, `RaftReadLog`, `RaftWriteLog`,
`RaftDeleteLog` and `RaftPersist`).

In our example, this monad is `RaftExampleM sm v`. See
[app/Main.hs](https://github.com/adjoint-io/raft/blob/master/app/Main.hs).

Finally, we are ready to run our Raft nodes. We call the `runRaftNode` function
from the
[src/Raft.hs](https://github.com/adjoint-io/raft/blob/master/src/Raft.hs)
file, together with the function we define to run the stack of monads that
derive our Raft type classes.

# References

1. Ongaro, D., Ousterhout, J. [In Search of an Understandable Consensus
   Algorithm](https://raft.github.io/raft.pdf), 2014

2. Howard, H. [ARC: Analysis of Raft
   Consensus](https://www.cl.cam.ac.uk/techreports/UCAM-CL-TR-857.pdf) 2014
