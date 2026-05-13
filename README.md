# slop.computer — Episode Registry

Onchain registry of [slop.computer](https://slop.computer) episodes plus a "live now" pointer. Episodes are stored in a singly-linked list with the head pointing at the newest entry — readers paginate from the head without needing an indexer or subgraph.

## Live Deployment

| Network | Address | Owner |
| --- | --- | --- |
| Ethereum Mainnet (chainId `1`) | [`0x5b448e5E6161dBd039F435b07Ba96b69ca2c76F3`](https://etherscan.io/address/0x5b448e5e6161dbd039f435b07ba96b69ca2c76f3) | [`atg.eth`](https://etherscan.io/address/0x34aA3F359A9D614239015126635CE7732c18fDF3) (`0x34aA3F359A9D614239015126635CE7732c18fDF3`) |

Source and tooling:

- **Contract source:** [`packages/foundry/contracts/SlopComputer.sol`](packages/foundry/contracts/SlopComputer.sol)
- **Deploy script:** [`packages/foundry/script/DeploySlopComputer.s.sol`](packages/foundry/script/DeploySlopComputer.s.sol)
- **ABI (auto-generated for the frontend):** [`packages/nextjs/contracts/deployedContracts.ts`](packages/nextjs/contracts/deployedContracts.ts) — keyed by chain id (`1` for mainnet, `31337` for local anvil)
- **Frontend:** [`packages/nextjs`](packages/nextjs) (Next.js + RainbowKit + Wagmi)

The deploy script (`DeploySlopComputer.s.sol`) hardcodes `atg.eth` as the owner on every non-local chain and reverts the broadcast if the post-construction owner doesn't match — belt-and-suspenders against accidental misdeploys.

## Data Model

### `Episode`

```solidity
struct Episode {
    bytes32 id;            // content-addressed; see "ID derivation" below
    string  name;          // display name, immutable per id
    address contractAddr;  // optional per-episode contract; mutable
    string  url;           // HLS / ipfs:// / https://… ; mutable
    uint256 datetime;      // unix seconds; immutable
    bytes32 nextId;        // next entry in the linked list; 0x0 at the tail
}
```

### Singleton state

| Storage | Type | Description |
| --- | --- | --- |
| `head` | `bytes32` | Newest episode id. `0x0` when the list is empty. |
| `live` | `bytes32` | Currently-live episode id. `0x0` when offline. |
| `episodeCount` | `uint256` | Number of episodes currently stored. |

### ID derivation

Episode ids are content-addressed by the immutable subset (`name`, `datetime`) plus this contract's address. `url` and `contractAddr` are mutable and intentionally excluded from the hash, so they can be swapped (e.g. live HLS → recorded `ipfs://…`) without changing the id.

```solidity
function getId(string memory name, uint256 datetime) public view returns (bytes32) {
    return keccak256(abi.encode(address(this), name, datetime));
}
```

Two episodes with the same `(name, datetime)` collide — the second call reverts with `EpisodeAlreadyExists(id)`.

## Reading the Registry

All read functions are `view` and free. No indexer required.

| Function | Returns | Notes |
| --- | --- | --- |
| `head()` | `bytes32` | Newest episode id. |
| `live()` | `bytes32` | Live episode id, or `0x0` when offline. |
| `episodeCount()` | `uint256` | Number of episodes. |
| `getEpisode(bytes32 id)` | `Episode` | Reverts `EpisodeNotFound` if missing. |
| `latest()` | `Episode` | Live episode if any, else head. Zero-struct (`id == 0x0`) if empty. |
| `liveEpisode()` | `Episode` | Live episode, or zero-struct when offline. |
| `indexOf(bytes32 id)` | `uint256` | Position from head (0 = newest). Reverts if missing. |
| `getEpisodes(uint256 index, uint256 amount)` | `Episode[]` | Page starting `index` from the head. |
| `getEpisodesFrom(bytes32 startId, uint256 amount)` | `Episode[]` | Cursor-based pagination; pass `0x0` for the first page, then pass the previous page's last `nextId`. |
| `getId(string name, uint256 datetime)` | `bytes32` | Derive the id `addEpisode` / `goLive` would assign for these inputs. |

## Writing to the Registry (owner-only)

All state-changing functions revert if not called by `owner()` (OpenZeppelin `Ownable`).

| Function | Description |
| --- | --- |
| `addEpisode(string name, address contractAddr, string url, uint256 datetime)` | Push a new episode to the head. Returns the new `bytes32 id`. |
| `goLive(string name, address contractAddr, string url, uint256 datetime)` | Push a new episode AND mark it as currently live. Returns the new `bytes32 id`. |
| `setLive(bytes32 id)` | Mark an existing episode as live (use to resume after `goOffline` — `goLive` would revert `EpisodeAlreadyExists` for the same content). |
| `setEpisodeContract(bytes32 id, address contractAddr)` | Update an episode's contract address. Id is unchanged. |
| `setEpisodeUrl(bytes32 id, string url)` | Update an episode's URL (live → recorded flow). Id is unchanged. |
| `goOffline()` | Clear the `live` pointer. The episode itself stays in the list. |
| `deleteEpisode(bytes32 id)` | Remove an episode from the list. Splices the linked list; clears `live` if it pointed here. |

## Events

```solidity
event EpisodeAdded(bytes32 indexed id, string name, address contractAddr, string url, uint256 datetime);
event EpisodeContractSet(bytes32 indexed id, address contractAddr);
event EpisodeUrlSet(bytes32 indexed id, string url);
event EpisodeDeleted(bytes32 indexed id);
event WentLive(bytes32 indexed id);
event WentOffline(bytes32 indexed previousLive);
```

## Errors

```solidity
error EpisodeNotFound(bytes32 id);
error EpisodeAlreadyExists(bytes32 id);
error NotLive();
```

## Frontend

The Next.js frontend in [`packages/nextjs`](packages/nextjs) reads from the live mainnet deployment by default. Network targeting is configured in [`packages/nextjs/scaffold.config.ts`](packages/nextjs/scaffold.config.ts):

```ts
targetNetworks: [chains.mainnet, chains.foundry],
```

Mainnet is the default; local anvil is available as a fallback for development.

The home page paginates the linked list from the head and highlights the live/latest episode via `latest()`. Contract reads go through the SE-2 hooks (`useScaffoldReadContract`, `useScaffoldEventHistory`) which pull the ABI and chain-keyed address from `deployedContracts.ts`.

## Local Development

This repo is a [Scaffold-ETH 2](https://scaffoldeth.io) project (Foundry flavor).

### Requirements

- [Node ≥ v20.18.3](https://nodejs.org/en/download/)
- [Yarn](https://classic.yarnpkg.com/en/docs/install/)
- [Foundry](https://book.getfoundry.sh/getting-started/installation)

### Quickstart

```bash
yarn install
yarn chain       # local anvil — terminal 1
yarn deploy      # terminal 2 — deploys SlopComputer to chainId 31337
yarn start       # terminal 3 — http://localhost:3000
```

On local anvil the deployer is set as `owner` so the **Debug Contracts** page can exercise owner-only methods (`addEpisode`, `goLive`, etc.).

### Tests

```bash
yarn foundry:test
```

### Deploy to a live network

```bash
# specifically deploy the SlopComputer
yarn deploy --file DeploySlopComputer.s.sol --network mainnet
```

The script reverts on any non-local chain unless the deployed owner is `atg.eth` — see [`DeploySlopComputer.s.sol`](packages/foundry/script/DeploySlopComputer.s.sol).

## Repo Layout

```
packages/
├── foundry/
│   ├── contracts/SlopComputer.sol          # the registry contract
│   ├── script/DeploySlopComputer.s.sol     # deploy script (atg.eth-guarded)
│   ├── test/                                # forge tests
│   └── foundry.toml                         # rpc endpoints, profile config
└── nextjs/
    ├── app/                                 # Next.js App Router pages
    ├── contracts/deployedContracts.ts       # auto-generated ABIs by chainId
    ├── hooks/scaffold-eth/                  # typed contract-read/write hooks
    └── scaffold.config.ts                   # target networks, polling, keys
```

## Tech Stack

Foundry · OpenZeppelin (`Ownable`) · Next.js 15 · RainbowKit · Wagmi · Viem · TypeScript · Tailwind + DaisyUI · [Scaffold-ETH 2](https://scaffoldeth.io).

## License

MIT — see [`LICENCE`](LICENCE).
