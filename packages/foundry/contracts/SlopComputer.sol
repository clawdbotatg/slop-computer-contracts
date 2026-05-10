// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*

   ███████╗██╗      ██████╗ ██████╗     ██████╗ ██████╗ ███╗   ███╗██████╗ ██╗   ██╗████████╗███████╗██████╗
   ██╔════╝██║     ██╔═══██╗██╔══██╗   ██╔════╝██╔═══██╗████╗ ████║██╔══██╗██║   ██║╚══██╔══╝██╔════╝██╔══██╗
   ███████╗██║     ██║   ██║██████╔╝   ██║     ██║   ██║██╔████╔██║██████╔╝██║   ██║   ██║   █████╗  ██████╔╝
   ╚════██║██║     ██║   ██║██╔═══╝    ██║     ██║   ██║██║╚██╔╝██║██╔═══╝ ██║   ██║   ██║   ██╔══╝  ██╔══██╗
   ███████║███████╗╚██████╔╝██║     ██╗╚██████╗╚██████╔╝██║ ╚═╝ ██║██║     ╚██████╔╝   ██║   ███████╗██║  ██║
   ╚══════╝╚══════╝ ╚═════╝ ╚═╝     ╚═╝ ╚═════╝ ╚═════╝ ╚═╝     ╚═╝╚═╝      ╚═════╝    ╚═╝   ╚══════╝╚═╝  ╚═╝

    Austin Griffith @austingriffith austin@ethereum.org
    ClawdBotATG @ClawdBotATG clawd@buidlguidl.com 
    
*/

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @title SlopComputer
/// @notice Onchain registry of slop.computer episodes plus a "live now" pointer.
///         Episodes are stored in a singly-linked list so the head is always the
///         newest entry — readers paginate from the head without indexers.
contract SlopComputer is Ownable {
    struct Episode {
        bytes32 id;
        string name;
        address contractAddr;
        string url;
        string datetime;
        bytes32 nextId;
    }

    /// @notice Newest episode in the list. `bytes32(0)` when the list is empty.
    bytes32 public head;

    /// @notice Currently live episode id, or `bytes32(0)` when offline.
    bytes32 public live;

    /// @notice Number of episodes currently stored.
    uint256 public episodeCount;

    mapping(bytes32 => Episode) private _episodes;

    event EpisodeAdded(bytes32 indexed id, string name, address contractAddr, string url, string datetime);
    event EpisodeContractSet(bytes32 indexed id, address contractAddr);
    event EpisodeUrlSet(bytes32 indexed id, string url);
    event EpisodeDeleted(bytes32 indexed id);
    event WentLive(bytes32 indexed id);
    event WentOffline(bytes32 indexed previousLive);

    error EpisodeNotFound(bytes32 id);
    error EpisodeAlreadyExists(bytes32 id);
    error NotLive();

    constructor(address initialOwner) Ownable(initialOwner) { }

    /// @notice Add a new episode at the head of the list.
    function addEpisode(string calldata name, address contractAddr, string calldata url, string calldata datetime)
        external
        onlyOwner
        returns (bytes32 id)
    {
        id = _addEpisode(name, contractAddr, url, datetime);
    }

    /// @notice Add a new episode at the head AND mark it as the currently-live episode.
    /// @dev    If a different episode is already live, its data is preserved in the list;
    ///         only the `live` pointer moves to the new one.
    function goLive(string calldata name, address contractAddr, string calldata url, string calldata datetime)
        external
        onlyOwner
        returns (bytes32 id)
    {
        id = _addEpisode(name, contractAddr, url, datetime);
        live = id;
        emit WentLive(id);
    }

    /// @notice Update the per-episode contract address. The episode id is unchanged
    ///         (ids are derived from name/datetime, not from this field), so
    ///         pagination and links keep working.
    function setEpisodeContract(bytes32 id, address contractAddr) external onlyOwner {
        if (_episodes[id].id == bytes32(0)) revert EpisodeNotFound(id);
        _episodes[id].contractAddr = contractAddr;
        emit EpisodeContractSet(id, contractAddr);
    }

    /// @notice Update the episode's url — useful for the live → recorded flow:
    ///         start with an HLS stream URL, swap to an `ipfs://cid` after the
    ///         recording is published. The id is unchanged.
    function setEpisodeUrl(bytes32 id, string calldata url) external onlyOwner {
        if (_episodes[id].id == bytes32(0)) revert EpisodeNotFound(id);
        _episodes[id].url = url;
        emit EpisodeUrlSet(id, url);
    }

    /// @notice Clear the live pointer. Episode itself stays in the list.
    function goOffline() external onlyOwner {
        bytes32 wasLive = live;
        if (wasLive == bytes32(0)) revert NotLive();
        live = bytes32(0);
        emit WentOffline(wasLive);
    }

    /// @notice Delete an episode and splice it out of the linked list.
    function deleteEpisode(bytes32 id) external onlyOwner {
        if (_episodes[id].id == bytes32(0)) revert EpisodeNotFound(id);

        bytes32 nextId = _episodes[id].nextId;

        if (head == id) {
            head = nextId;
        } else {
            // Walk from head to find the predecessor. The id is known to exist
            // and is not the head, so a predecessor must exist.
            bytes32 cursor = head;
            while (_episodes[cursor].nextId != id) {
                cursor = _episodes[cursor].nextId;
            }
            _episodes[cursor].nextId = nextId;
        }

        if (live == id) live = bytes32(0);

        delete _episodes[id];
        unchecked {
            episodeCount -= 1;
        }
        emit EpisodeDeleted(id);
    }

    /// @notice Compute the id that `addEpisode` / `goLive` will produce for these fields.
    ///         Content-addressed by the immutable subset: same (this, name, datetime) → same id.
    ///         `url` and `contractAddr` are mutable post-add via setters and intentionally
    ///         excluded from the hash.
    function getId(string memory name, string memory datetime) public view returns (bytes32) {
        return keccak256(abi.encode(address(this), name, datetime));
    }

    /// @notice Read a single episode by id. Reverts if not found.
    function getEpisode(bytes32 id) external view returns (Episode memory) {
        Episode memory ep = _episodes[id];
        if (ep.id == bytes32(0)) revert EpisodeNotFound(id);
        return ep;
    }

    /// @notice Episode to show in the hero slot: the live episode if any, else the
    ///         newest (head). Returns a zero-struct (id == bytes32(0)) when the list
    ///         is empty, so the caller doesn't need a try/catch.
    function latest() external view returns (Episode memory) {
        bytes32 id = live != bytes32(0) ? live : head;
        return _episodes[id]; // zero-struct when id is bytes32(0)
    }

    /// @notice Position of `id` in the linked list, counted from the head.
    ///         Head returns 0. Reverts if `id` doesn't exist.
    function indexOf(bytes32 id) external view returns (uint256 index) {
        if (_episodes[id].id == bytes32(0)) revert EpisodeNotFound(id);
        bytes32 cursor = head;
        while (cursor != id) {
            cursor = _episodes[cursor].nextId;
            unchecked {
                index += 1;
            }
        }
    }

    /// @notice Paginated read from the head of the list.
    /// @param  index  number of episodes to skip from the head (0 = start at newest)
    /// @param  amount maximum number of episodes to return
    /// @return episodes from `index` to `index + amount - 1` (or fewer if the list ends)
    function getEpisodes(uint256 index, uint256 amount) external view returns (Episode[] memory episodes) {
        bytes32 cursor = head;
        for (uint256 i = 0; i < index && cursor != bytes32(0); i++) {
            cursor = _episodes[cursor].nextId;
        }
        episodes = _readFrom(cursor, amount);
    }

    /// @notice Cursor-based pagination — cheaper than `getEpisodes` for sequential reads.
    /// @dev    Pass `bytes32(0)` for the first page; for subsequent pages pass
    ///         `episodes[episodes.length - 1].nextId` from the previous page.
    /// @param  startId id to start reading at; `bytes32(0)` starts from `head`.
    ///                 Reverts if `startId` is set but no longer exists.
    /// @param  amount  maximum number of episodes to return
    function getEpisodesFrom(bytes32 startId, uint256 amount) external view returns (Episode[] memory episodes) {
        bytes32 cursor;
        if (startId == bytes32(0)) {
            cursor = head;
        } else {
            if (_episodes[startId].id == bytes32(0)) revert EpisodeNotFound(startId);
            cursor = startId;
        }
        episodes = _readFrom(cursor, amount);
    }

    function _readFrom(bytes32 cursor, uint256 amount) internal view returns (Episode[] memory episodes) {
        bytes32 walker = cursor;
        uint256 actual = 0;
        while (actual < amount && walker != bytes32(0)) {
            actual++;
            walker = _episodes[walker].nextId;
        }

        episodes = new Episode[](actual);
        for (uint256 i = 0; i < actual; i++) {
            episodes[i] = _episodes[cursor];
            cursor = _episodes[cursor].nextId;
        }
    }

    function _addEpisode(string calldata name, address contractAddr, string calldata url, string calldata datetime)
        internal
        returns (bytes32 id)
    {
        id = getId(name, datetime);
        if (_episodes[id].id != bytes32(0)) revert EpisodeAlreadyExists(id);

        _episodes[id] =
            Episode({ id: id, name: name, contractAddr: contractAddr, url: url, datetime: datetime, nextId: head });
        head = id;
        episodeCount += 1;

        emit EpisodeAdded(id, name, contractAddr, url, datetime);
    }
}
