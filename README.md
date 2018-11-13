# Raft

Adjoint's implementation of the Raft protocol

# Getting started

To run an example:

1) Build the example executable:
```$ stack build ```

2) In separate terminals, run some raft nodes:

The format of the cmd line invocation is:
``` raft-example <node-id> <peer-1-node-id> ... <peer-n-node-id> ```

Here's an example of a network of two nodes:

On terminal 1:
```$ stack exec raft-example localhost:3001 localhost:3002```

On terminal 2:
```$ stack exec raft-example localhost:3002 localhost:3001```

The first node spawned should immediately become candidate and then leader once
its election's timer times out. The second node will acknowledge the new leader.
They will exchange messages for each heartbeat.

3) Run a client:
``` stack exec raft-example client```

In the example provided, there are five basic operations:

  - ``` addNode <host:port> ```
  It adds a nodeId to the set of nodeIds that the client will communicate with

  - ``` getNodes ```
  It returns the node ids that the client is aware of

  - ``` read ```
  It returns the state of the leader

  - ``` set <var> <val> ```
  It sets a variable to a specific value

  - ``` incr <var> ```
  It increments the value of a variable

Assuming that two nodes are run as mentioned above, a valid client workflow
would be:
```
>>> addNode localhost:3001
>>> set testVar 4
>>> incr testVar
>>> read
```

It will return the state of the leader's state machine after those changes,
which in this case will be a map: `Map.fromList [("testVar",5)]`
