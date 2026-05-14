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
///
///         Each episode keeps four lightweight fields on chain for fast listing
///         (name, slug, datetime, contractAddr) and a single `manifest` string —
///         an `ipfs://<cid>` pointer to a JSON document that carries everything
///         else: video CID, transcript CID, chat CID, description, participants,
///         attached files, etc. The manifest is mutable; pointed-to content is
///         immutable (content-addressed). Bump the manifest CID to publish edits.
///
///         The frontend resolves `/[slug]` against `slugToId` for O(1) lookup;
///         slugs are 1-64 chars of `[a-z0-9-]`, must not start or end with a
///         dash, and are unique across the registry. When the show is live
///         (`live == id`), the frontend ignores `manifest` and plays the global
///         HLS endpoint instead.
contract SlopComputer is Ownable {
    struct Episode {
        bytes32 id;
        /// @dev Display name. Immutable after creation; one half of the (name,
        ///      datetime) pair that derives `id`.
        string name;
        string slug;
        /// @dev `ipfs://<cid>` to the manifest JSON. May be empty during live.
        string manifest;
        address contractAddr;
        uint256 datetime; // unix seconds — immutable
        bytes32 nextId;
    }

    /// @notice Newest episode in the list. `bytes32(0)` when the list is empty.
    bytes32 public head;

    /// @notice Currently live episode id, or `bytes32(0)` when offline.
    bytes32 public live;

    /// @notice Number of episodes currently stored.
    uint256 public episodeCount;

    /// @notice `slug → id` lookup, populated on add and kept in sync on
    ///         setSlug / deleteEpisode. Public so the frontend can read it
    ///         directly via the generated getter.
    mapping(string => bytes32) public slugToId;

    mapping(bytes32 => Episode) private _episodes;

    event EpisodeAdded(
        bytes32 indexed id, string name, string slug, string manifest, address contractAddr, uint256 datetime
    );
    event EpisodeSlugSet(bytes32 indexed id, string slug);
    event EpisodeManifestSet(bytes32 indexed id, string manifest);
    event EpisodeContractSet(bytes32 indexed id, address contractAddr);
    event EpisodeDeleted(bytes32 indexed id);
    event WentLive(bytes32 indexed id);
    event WentOffline(bytes32 indexed previousLive);

    error EpisodeNotFound(bytes32 id);
    error EpisodeAlreadyExists(bytes32 id);
    error SlugInvalid();
    error SlugAlreadyTaken();
    error SlugNotFound(string slug);
    error NotLive();

    constructor(address initialOwner) Ownable(initialOwner) { }

    /// @notice Add a new episode at the head of the list.
    function addEpisode(
        string calldata name,
        string calldata slug,
        string calldata manifest,
        address contractAddr,
        uint256 datetime
    ) external onlyOwner returns (bytes32 id) {
        id = _addEpisode(name, slug, manifest, contractAddr, datetime);
    }

    /// @notice Add a new episode at the head AND mark it as the currently-live episode.
    /// @dev    If a different episode is already live, its data is preserved in the list;
    ///         only the `live` pointer moves to the new one. `manifest` can be empty —
    ///         the frontend ignores it while `live == id` (plays the HLS endpoint).
    function goLive(
        string calldata name,
        string calldata slug,
        string calldata manifest,
        address contractAddr,
        uint256 datetime
    ) external onlyOwner returns (bytes32 id) {
        id = _addEpisode(name, slug, manifest, contractAddr, datetime);
        live = id;
        emit WentLive(id);
    }

    /// @notice Mark an existing episode as currently live without creating a new one.
    ///         Use this to resume a stream after `goOffline` — `goLive` would revert
    ///         with `EpisodeAlreadyExists` for the same content.
    function setLive(bytes32 id) external onlyOwner {
        if (_episodes[id].id == bytes32(0)) revert EpisodeNotFound(id);
        live = id;
        emit WentLive(id);
    }

    /// @notice Change the episode's slug. Validates format + uniqueness and
    ///         updates the `slugToId` index in lockstep.
    function setSlug(bytes32 id, string calldata newSlug) external onlyOwner {
        Episode storage ep = _episodes[id];
        if (ep.id == bytes32(0)) revert EpisodeNotFound(id);
        if (!_isValidSlug(newSlug)) revert SlugInvalid();

        // Allow a no-op rename (same slug → same id) but reject collisions.
        bytes32 holder = slugToId[newSlug];
        if (holder != bytes32(0) && holder != id) revert SlugAlreadyTaken();

        delete slugToId[ep.slug];
        ep.slug = newSlug;
        slugToId[newSlug] = id;
        emit EpisodeSlugSet(id, newSlug);
    }

    /// @notice Update the manifest pointer — the live → recorded flow lives here.
    ///         Start live with empty `manifest`, then set it to `ipfs://<cid>` after
    ///         finalize. Re-call anytime to publish an edited manifest.
    function setManifest(bytes32 id, string calldata manifest) external onlyOwner {
        if (_episodes[id].id == bytes32(0)) revert EpisodeNotFound(id);
        _episodes[id].manifest = manifest;
        emit EpisodeManifestSet(id, manifest);
    }

    /// @notice Update the per-episode contract address. The id is unchanged.
    function setEpisodeContract(bytes32 id, address contractAddr) external onlyOwner {
        if (_episodes[id].id == bytes32(0)) revert EpisodeNotFound(id);
        _episodes[id].contractAddr = contractAddr;
        emit EpisodeContractSet(id, contractAddr);
    }

    /// @notice Clear the live pointer. Episode itself stays in the list.
    function goOffline() external onlyOwner {
        bytes32 wasLive = live;
        if (wasLive == bytes32(0)) revert NotLive();
        live = bytes32(0);
        emit WentOffline(wasLive);
    }

    /// @notice Delete an episode and splice it out of the linked list. Clears
    ///         the slug index so the slug becomes reusable.
    function deleteEpisode(bytes32 id) external onlyOwner {
        Episode storage ep = _episodes[id];
        if (ep.id == bytes32(0)) revert EpisodeNotFound(id);

        bytes32 nextId = ep.nextId;
        string memory slug = ep.slug;

        if (head == id) {
            head = nextId;
        } else {
            // Walk from head to find the predecessor. The existence check above
            // guarantees we'll hit `id` before running off the tail; the bytes32(0)
            // bound is belt-and-suspenders for invariant drift.
            bytes32 cursor = head;
            while (cursor != bytes32(0) && _episodes[cursor].nextId != id) {
                cursor = _episodes[cursor].nextId;
            }
            if (cursor == bytes32(0)) revert EpisodeNotFound(id);
            _episodes[cursor].nextId = nextId;
        }

        if (live == id) live = bytes32(0);

        delete _episodes[id];
        delete slugToId[slug];
        unchecked {
            episodeCount -= 1;
        }
        emit EpisodeDeleted(id);
    }

    /// @notice Compute the id that `addEpisode` / `goLive` will produce for these fields.
    ///         Ids are content-addressed by the immutable pair `(name, datetime)` plus
    ///         this contract's address. Slug, manifest, contractAddr are mutable post-add
    ///         and intentionally excluded.
    function getId(string memory name, uint256 datetime) public view returns (bytes32) {
        return keccak256(abi.encode(address(this), name, datetime));
    }

    /// @notice Read a single episode by id. Reverts if not found.
    function getEpisode(bytes32 id) external view returns (Episode memory) {
        Episode memory ep = _episodes[id];
        if (ep.id == bytes32(0)) revert EpisodeNotFound(id);
        return ep;
    }

    /// @notice Read a single episode by slug. Reverts `SlugNotFound(slug)` if no
    ///         episode owns the slug.
    function getEpisodeBySlug(string calldata slug) external view returns (Episode memory) {
        bytes32 id = slugToId[slug];
        if (id == bytes32(0)) revert SlugNotFound(slug);
        return _episodes[id];
    }

    /// @notice Episode to show in the hero slot: the live episode if any, else the
    ///         newest (head). Returns a zero-struct (id == bytes32(0)) when the list
    ///         is empty, so the caller doesn't need a try/catch.
    function latest() external view returns (Episode memory) {
        bytes32 id = live != bytes32(0) ? live : head;
        return _episodes[id]; // zero-struct when id is bytes32(0)
    }

    /// @notice Live episode struct (or zero-struct when offline).
    function liveEpisode() external view returns (Episode memory) {
        return _episodes[live];
    }

    /// @notice Position of `id` in the linked list, counted from the head.
    function indexOf(bytes32 id) external view returns (uint256 index) {
        if (_episodes[id].id == bytes32(0)) revert EpisodeNotFound(id);
        bytes32 cursor = head;
        while (cursor != id) {
            if (cursor == bytes32(0)) revert EpisodeNotFound(id);
            cursor = _episodes[cursor].nextId;
            unchecked {
                index += 1;
            }
        }
    }

    /// @notice Paginated read from the head of the list.
    function getEpisodes(uint256 index, uint256 amount) external view returns (Episode[] memory episodes) {
        bytes32 cursor = head;
        for (uint256 i = 0; i < index && cursor != bytes32(0); i++) {
            cursor = _episodes[cursor].nextId;
        }
        episodes = _readFrom(cursor, amount);
    }

    /// @notice Cursor-based pagination — cheaper than `getEpisodes` for sequential reads.
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

    function _addEpisode(
        string memory name,
        string memory slug,
        string memory manifest,
        address contractAddr,
        uint256 datetime
    ) internal returns (bytes32 id) {
        if (!_isValidSlug(slug)) revert SlugInvalid();

        // Check content-uniqueness before slug-uniqueness so a true duplicate
        // (same name+datetime) reports as EpisodeAlreadyExists even when the
        // caller happens to reuse the original slug too.
        id = getId(name, datetime);
        if (_episodes[id].id != bytes32(0)) revert EpisodeAlreadyExists(id);
        if (slugToId[slug] != bytes32(0)) revert SlugAlreadyTaken();

        _episodes[id] = Episode({
            id: id,
            name: name,
            slug: slug,
            manifest: manifest,
            contractAddr: contractAddr,
            datetime: datetime,
            nextId: head
        });
        slugToId[slug] = id;
        head = id;
        episodeCount += 1;

        emit EpisodeAdded(id, name, slug, manifest, contractAddr, datetime);
    }

    /// @dev Slugs are 1-64 chars of `[a-z0-9-]` and must not start or end with a
    ///      dash. Double dashes inside the slug are allowed.
    function _isValidSlug(string memory s) internal pure returns (bool) {
        bytes memory b = bytes(s);
        uint256 len = b.length;
        if (len == 0 || len > 64) return false;
        if (b[0] == 0x2d || b[len - 1] == 0x2d) return false;
        for (uint256 i = 0; i < len; i++) {
            bytes1 c = b[i];
            bool isDigit = c >= 0x30 && c <= 0x39;
            bool isLower = c >= 0x61 && c <= 0x7a;
            bool isDash = c == 0x2d;
            if (!isDigit && !isLower && !isDash) return false;
        }
        return true;
    }
}
