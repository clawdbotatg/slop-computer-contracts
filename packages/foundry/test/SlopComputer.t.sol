// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { SlopComputer } from "../contracts/SlopComputer.sol";

contract SlopComputerTest is Test {
    SlopComputer internal sc;
    address internal owner = address(0xA76);
    address internal stranger = address(0xB0B);

    function setUp() public {
        sc = new SlopComputer(owner);
    }

    // -------------------------------------------------------------------------
    // ownership
    // -------------------------------------------------------------------------

    function test_owner_isInitialOwner() public view {
        assertEq(sc.owner(), owner);
    }

    function test_constructor_revertsOnZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new SlopComputer(address(0));
    }

    function test_addEpisode_revertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        sc.addEpisode("ep", address(0), "ipfs://x", "2026-01-01");
    }

    function test_goLive_revertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        sc.goLive("ep", address(0), "ipfs://x", "2026-01-01");
    }

    function test_deleteEpisode_revertsForNonOwner() public {
        bytes32 id = _addAs(owner, "ep1");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        sc.deleteEpisode(id);
    }

    // -------------------------------------------------------------------------
    // addEpisode
    // -------------------------------------------------------------------------

    function test_addEpisode_setsHeadAndCount() public {
        bytes32 id = _addAs(owner, "first");
        assertEq(sc.head(), id);
        assertEq(sc.episodeCount(), 1);

        SlopComputer.Episode memory ep = sc.getEpisode(id);
        assertEq(ep.id, id);
        assertEq(ep.name, "first");
        assertEq(ep.nextId, bytes32(0));
    }

    function test_addEpisode_pushesToHead() public {
        bytes32 a = _addAs(owner, "a");
        bytes32 b = _addAs(owner, "b");
        bytes32 c = _addAs(owner, "c");

        assertEq(sc.head(), c);
        assertEq(sc.episodeCount(), 3);

        // c -> b -> a
        assertEq(sc.getEpisode(c).nextId, b);
        assertEq(sc.getEpisode(b).nextId, a);
        assertEq(sc.getEpisode(a).nextId, bytes32(0));
    }

    function test_addEpisode_idsAreUnique() public {
        bytes32 a = _addAs(owner, "a");
        bytes32 b = _addAs(owner, "b");
        assertTrue(a != b);
    }

    function test_getId_matchesIdAddEpisodeProduces() public {
        // _addAs uses datetime="2026-01-01"
        bytes32 actual = _addAs(owner, "a");
        assertEq(sc.getId("a", "2026-01-01"), actual);
    }

    function test_getId_isDeterministic() public view {
        bytes32 once = sc.getId("a", "dt");
        bytes32 twice = sc.getId("a", "dt");
        assertEq(once, twice);
    }

    function test_getId_ignoresUrlAndContractAddr() public {
        // url and contractAddr are mutable via setters, so they must not be part of the id.
        // Adding two episodes with the same (name, datetime) must collide regardless of url.
        vm.prank(owner);
        sc.addEpisode("name", address(0xAAA), "url-a", "2026-01-01");
        bytes32 expected = sc.getId("name", "2026-01-01");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SlopComputer.EpisodeAlreadyExists.selector, expected));
        sc.addEpisode("name", address(0xBBB), "url-b", "2026-01-01");
    }

    function test_getId_differsAcrossContractAddresses() public {
        SlopComputer other = new SlopComputer(owner);
        // Same content, but different `address(this)` → different id.
        assertTrue(sc.getId("a", "dt") != other.getId("a", "dt"));
    }

    function test_addEpisode_revertsOnDuplicateContent() public {
        _addAs(owner, "dup");
        bytes32 expected = sc.getId("dup", "2026-01-01");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SlopComputer.EpisodeAlreadyExists.selector, expected));
        sc.addEpisode("dup", address(0), "different-url", "2026-01-01");
    }

    function test_addEpisode_canReuseIdAfterDelete() public {
        bytes32 id = _addAs(owner, "reused");
        vm.prank(owner);
        sc.deleteEpisode(id);
        bytes32 readded = _addAs(owner, "reused");
        assertEq(id, readded);
        assertEq(sc.episodeCount(), 1);
    }

    // -------------------------------------------------------------------------
    // setEpisodeContract
    // -------------------------------------------------------------------------

    function test_setEpisodeContract_updatesField() public {
        bytes32 id = _addAs(owner, "ep");
        address newAddr = address(0xABCD);
        vm.prank(owner);
        sc.setEpisodeContract(id, newAddr);
        assertEq(sc.getEpisode(id).contractAddr, newAddr);
    }

    function test_setEpisodeContract_doesNotChangeId() public {
        bytes32 id = _addAs(owner, "ep");
        vm.prank(owner);
        sc.setEpisodeContract(id, address(0xABCD));
        // head still points at the same id; episode still retrievable by it
        assertEq(sc.head(), id);
        assertEq(sc.getEpisode(id).id, id);
    }

    function test_setEpisodeContract_revertsForNonOwner() public {
        bytes32 id = _addAs(owner, "ep");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        sc.setEpisodeContract(id, address(0xABCD));
    }

    function test_setEpisodeContract_revertsForUnknownId() public {
        bytes32 fake = keccak256("nope");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SlopComputer.EpisodeNotFound.selector, fake));
        sc.setEpisodeContract(fake, address(0xABCD));
    }

    // -------------------------------------------------------------------------
    // setEpisodeUrl — the live → recorded flow
    // -------------------------------------------------------------------------

    function test_setEpisodeUrl_updatesField() public {
        bytes32 id = _addAs(owner, "ep");
        vm.prank(owner);
        sc.setEpisodeUrl(id, "ipfs://recorded");
        assertEq(sc.getEpisode(id).url, "ipfs://recorded");
    }

    function test_setEpisodeUrl_doesNotChangeId() public {
        bytes32 id = _addAs(owner, "ep");
        vm.prank(owner);
        sc.setEpisodeUrl(id, "anything");
        assertEq(sc.head(), id);
        assertEq(sc.getEpisode(id).id, id);
    }

    function test_setEpisodeUrl_liveToRecordedFlow() public {
        // Owner goes live with an HLS stream url, then swaps to ipfs:// after recording.
        vm.prank(owner);
        bytes32 id = sc.goLive("episode 1", address(0), "https://hls.example/live.m3u8", "2026-05-09");
        assertEq(sc.live(), id);

        vm.prank(owner);
        sc.goOffline();

        vm.prank(owner);
        sc.setEpisodeUrl(id, "ipfs://QmRecorded");

        SlopComputer.Episode memory ep = sc.getEpisode(id);
        assertEq(ep.url, "ipfs://QmRecorded");
        assertEq(ep.id, id); // id stable across the whole flow
    }

    function test_setEpisodeUrl_revertsForNonOwner() public {
        bytes32 id = _addAs(owner, "ep");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        sc.setEpisodeUrl(id, "ipfs://nope");
    }

    function test_setEpisodeUrl_revertsForUnknownId() public {
        bytes32 fake = keccak256("nope");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SlopComputer.EpisodeNotFound.selector, fake));
        sc.setEpisodeUrl(fake, "ipfs://nope");
    }

    function test_addEpisode_emitsEvent() public {
        // We can't predict the id ahead of time, so we just check the event was emitted
        // with matching string fields by recording logs.
        vm.recordLogs();
        vm.prank(owner);
        sc.addEpisode("hello", address(0xCAFE), "ipfs://abc", "2026-05-09");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertEq(entries.length, 1);
        // EpisodeAdded(bytes32 indexed id, string name, address contractAddr, string url, string datetime)
        assertEq(entries[0].topics[0], keccak256("EpisodeAdded(bytes32,string,address,string,string)"));
    }

    // -------------------------------------------------------------------------
    // goLive / goOffline
    // -------------------------------------------------------------------------

    function test_goLive_setsLivePointer() public {
        bytes32 id = _goLiveAs(owner, "live show");
        assertEq(sc.live(), id);
        assertEq(sc.head(), id);
        assertEq(sc.episodeCount(), 1);
    }

    function test_goLive_replacesPreviousLiveButKeepsOldEpisodeInList() public {
        bytes32 first = _goLiveAs(owner, "first");
        bytes32 second = _goLiveAs(owner, "second");
        assertEq(sc.live(), second);
        assertEq(sc.episodeCount(), 2);
        // first is still in the list, just no longer live
        assertEq(sc.getEpisode(first).name, "first");
        assertEq(sc.getEpisode(first).nextId, bytes32(0));
        assertEq(sc.getEpisode(second).nextId, first);
    }

    function test_goOffline_clearsLive() public {
        bytes32 id = _goLiveAs(owner, "show");
        vm.prank(owner);
        sc.goOffline();
        assertEq(sc.live(), bytes32(0));
        // episode itself stays
        assertEq(sc.getEpisode(id).name, "show");
        assertEq(sc.episodeCount(), 1);
    }

    function test_goOffline_revertsWhenNotLive() public {
        vm.prank(owner);
        vm.expectRevert(SlopComputer.NotLive.selector);
        sc.goOffline();
    }

    function test_goOffline_revertsForNonOwner() public {
        _goLiveAs(owner, "show");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        sc.goOffline();
    }

    // -------------------------------------------------------------------------
    // deleteEpisode
    // -------------------------------------------------------------------------

    function test_delete_onlyEpisode() public {
        bytes32 id = _addAs(owner, "only");
        vm.prank(owner);
        sc.deleteEpisode(id);
        assertEq(sc.head(), bytes32(0));
        assertEq(sc.episodeCount(), 0);
        vm.expectRevert(abi.encodeWithSelector(SlopComputer.EpisodeNotFound.selector, id));
        sc.getEpisode(id);
    }

    function test_delete_head() public {
        bytes32 a = _addAs(owner, "a");
        bytes32 b = _addAs(owner, "b");
        bytes32 c = _addAs(owner, "c");

        vm.prank(owner);
        sc.deleteEpisode(c);

        assertEq(sc.head(), b);
        assertEq(sc.getEpisode(b).nextId, a);
        assertEq(sc.episodeCount(), 2);
    }

    function test_delete_middle() public {
        bytes32 a = _addAs(owner, "a");
        bytes32 b = _addAs(owner, "b");
        bytes32 c = _addAs(owner, "c");

        vm.prank(owner);
        sc.deleteEpisode(b);

        // c -> a (b spliced out)
        assertEq(sc.head(), c);
        assertEq(sc.getEpisode(c).nextId, a);
        assertEq(sc.getEpisode(a).nextId, bytes32(0));
        assertEq(sc.episodeCount(), 2);
    }

    function test_delete_tail() public {
        bytes32 a = _addAs(owner, "a");
        bytes32 b = _addAs(owner, "b");
        bytes32 c = _addAs(owner, "c");

        vm.prank(owner);
        sc.deleteEpisode(a);

        assertEq(sc.head(), c);
        assertEq(sc.getEpisode(c).nextId, b);
        assertEq(sc.getEpisode(b).nextId, bytes32(0));
        assertEq(sc.episodeCount(), 2);
    }

    function test_delete_clearsLiveIfPointed() public {
        bytes32 id = _goLiveAs(owner, "live");
        vm.prank(owner);
        sc.deleteEpisode(id);
        assertEq(sc.live(), bytes32(0));
    }

    function test_delete_doesNotClearLiveIfDifferent() public {
        bytes32 a = _addAs(owner, "a");
        bytes32 b = _goLiveAs(owner, "live");
        vm.prank(owner);
        sc.deleteEpisode(a);
        assertEq(sc.live(), b);
    }

    function test_delete_revertsForNonExistent() public {
        bytes32 fake = keccak256("nope");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SlopComputer.EpisodeNotFound.selector, fake));
        sc.deleteEpisode(fake);
    }

    // -------------------------------------------------------------------------
    // getEpisodes pagination
    // -------------------------------------------------------------------------

    function test_getEpisodes_emptyList() public view {
        SlopComputer.Episode[] memory eps = sc.getEpisodes(0, 10);
        assertEq(eps.length, 0);
    }

    function test_getEpisodes_returnsNewestFirst() public {
        _addAs(owner, "a");
        _addAs(owner, "b");
        _addAs(owner, "c");

        SlopComputer.Episode[] memory eps = sc.getEpisodes(0, 10);
        assertEq(eps.length, 3);
        assertEq(eps[0].name, "c");
        assertEq(eps[1].name, "b");
        assertEq(eps[2].name, "a");
    }

    function test_getEpisodes_respectsAmount() public {
        _addAs(owner, "a");
        _addAs(owner, "b");
        _addAs(owner, "c");

        SlopComputer.Episode[] memory eps = sc.getEpisodes(0, 2);
        assertEq(eps.length, 2);
        assertEq(eps[0].name, "c");
        assertEq(eps[1].name, "b");
    }

    function test_getEpisodes_respectsIndex() public {
        _addAs(owner, "a");
        _addAs(owner, "b");
        _addAs(owner, "c");
        _addAs(owner, "d");

        SlopComputer.Episode[] memory eps = sc.getEpisodes(2, 10);
        assertEq(eps.length, 2);
        assertEq(eps[0].name, "b");
        assertEq(eps[1].name, "a");
    }

    function test_getEpisodes_indexBeyondLength() public {
        _addAs(owner, "a");
        SlopComputer.Episode[] memory eps = sc.getEpisodes(5, 10);
        assertEq(eps.length, 0);
    }

    function test_getEpisodes_amountZero() public {
        _addAs(owner, "a");
        SlopComputer.Episode[] memory eps = sc.getEpisodes(0, 0);
        assertEq(eps.length, 0);
    }

    function test_getEpisodes_pagesThroughList() public {
        _addAs(owner, "a");
        _addAs(owner, "b");
        _addAs(owner, "c");
        _addAs(owner, "d");
        _addAs(owner, "e");

        SlopComputer.Episode[] memory page1 = sc.getEpisodes(0, 2);
        SlopComputer.Episode[] memory page2 = sc.getEpisodes(2, 2);
        SlopComputer.Episode[] memory page3 = sc.getEpisodes(4, 2);

        assertEq(page1[0].name, "e");
        assertEq(page1[1].name, "d");
        assertEq(page2[0].name, "c");
        assertEq(page2[1].name, "b");
        assertEq(page3.length, 1);
        assertEq(page3[0].name, "a");
    }

    // -------------------------------------------------------------------------
    // getEpisodesFrom — cursor-based pagination
    // -------------------------------------------------------------------------

    function test_getEpisodesFrom_zeroCursorStartsAtHead() public {
        _addAs(owner, "a");
        _addAs(owner, "b");
        _addAs(owner, "c");

        SlopComputer.Episode[] memory eps = sc.getEpisodesFrom(bytes32(0), 10);
        assertEq(eps.length, 3);
        assertEq(eps[0].name, "c");
        assertEq(eps[2].name, "a");
    }

    function test_getEpisodesFrom_walksWholeListInPages() public {
        // Add 7 episodes — pages of 3 should yield 3,3,1.
        bytes32[] memory ids = new bytes32[](7);
        ids[0] = _addAs(owner, "ep0"); // tail
        ids[1] = _addAs(owner, "ep1");
        ids[2] = _addAs(owner, "ep2");
        ids[3] = _addAs(owner, "ep3");
        ids[4] = _addAs(owner, "ep4");
        ids[5] = _addAs(owner, "ep5");
        ids[6] = _addAs(owner, "ep6"); // head (newest)

        SlopComputer.Episode[] memory page1 = sc.getEpisodesFrom(bytes32(0), 3);
        SlopComputer.Episode[] memory page2 = sc.getEpisodesFrom(page1[page1.length - 1].nextId, 3);
        SlopComputer.Episode[] memory page3 = sc.getEpisodesFrom(page2[page2.length - 1].nextId, 3);

        assertEq(page1.length, 3);
        assertEq(page1[0].name, "ep6");
        assertEq(page1[1].name, "ep5");
        assertEq(page1[2].name, "ep4");

        assertEq(page2.length, 3);
        assertEq(page2[0].name, "ep3");
        assertEq(page2[1].name, "ep2");
        assertEq(page2[2].name, "ep1");

        assertEq(page3.length, 1);
        assertEq(page3[0].name, "ep0");
        // tail's nextId is zero — caller knows to stop here
        assertEq(page3[page3.length - 1].nextId, bytes32(0));
    }

    function test_getEpisodesFrom_revertsForUnknownCursor() public {
        _addAs(owner, "a");
        bytes32 fake = keccak256("nope");
        vm.expectRevert(abi.encodeWithSelector(SlopComputer.EpisodeNotFound.selector, fake));
        sc.getEpisodesFrom(fake, 5);
    }

    function test_getEpisodesFrom_emptyListZeroCursorReturnsEmpty() public view {
        SlopComputer.Episode[] memory eps = sc.getEpisodesFrom(bytes32(0), 10);
        assertEq(eps.length, 0);
    }

    // -------------------------------------------------------------------------
    // latest()
    // -------------------------------------------------------------------------

    function test_latest_returnsZeroStructWhenEmpty() public view {
        SlopComputer.Episode memory ep = sc.latest();
        assertEq(ep.id, bytes32(0));
        assertEq(ep.name, "");
    }

    function test_latest_returnsHeadWhenNoLive() public {
        _addAs(owner, "a");
        bytes32 b = _addAs(owner, "b");
        SlopComputer.Episode memory ep = sc.latest();
        assertEq(ep.id, b);
        assertEq(ep.name, "b");
    }

    function test_latest_returnsLiveWhenSet() public {
        _addAs(owner, "old");
        bytes32 liveId = _goLiveAs(owner, "live");
        _addAs(owner, "newer-than-live");
        SlopComputer.Episode memory ep = sc.latest();
        // Even though a newer non-live episode is at head, latest() follows live.
        assertEq(ep.id, liveId);
        assertEq(ep.name, "live");
    }

    function test_latest_fallsBackToHeadAfterGoOffline() public {
        _addAs(owner, "first");
        _goLiveAs(owner, "live");
        bytes32 last = _addAs(owner, "last");
        vm.prank(owner);
        sc.goOffline();
        assertEq(sc.latest().id, last);
    }

    // -------------------------------------------------------------------------
    // indexOf
    // -------------------------------------------------------------------------

    function test_indexOf_head() public {
        _addAs(owner, "a");
        _addAs(owner, "b");
        bytes32 c = _addAs(owner, "c");
        assertEq(sc.indexOf(c), 0);
    }

    function test_indexOf_middle() public {
        _addAs(owner, "a");
        bytes32 b = _addAs(owner, "b");
        _addAs(owner, "c");
        assertEq(sc.indexOf(b), 1);
    }

    function test_indexOf_tail() public {
        bytes32 a = _addAs(owner, "a");
        _addAs(owner, "b");
        _addAs(owner, "c");
        assertEq(sc.indexOf(a), 2);
    }

    function test_indexOf_revertsForUnknownId() public {
        bytes32 fake = keccak256("nope");
        vm.expectRevert(abi.encodeWithSelector(SlopComputer.EpisodeNotFound.selector, fake));
        sc.indexOf(fake);
    }

    function test_indexOf_updatesAfterDelete() public {
        bytes32 a = _addAs(owner, "a");
        bytes32 b = _addAs(owner, "b");
        _addAs(owner, "c");
        // a is at index 2 initially
        assertEq(sc.indexOf(a), 2);
        // delete b → a moves up to index 1
        vm.prank(owner);
        sc.deleteEpisode(b);
        assertEq(sc.indexOf(a), 1);
    }

    // -------------------------------------------------------------------------
    // ownership transfer (sanity check that OZ is wired correctly)
    // -------------------------------------------------------------------------

    function test_transferOwnership_movesOwner() public {
        address newOwner = address(0xCAFE);
        vm.prank(owner);
        sc.transferOwnership(newOwner);
        assertEq(sc.owner(), newOwner);

        vm.prank(newOwner);
        sc.addEpisode("post-handoff", address(0), "", "");
        assertEq(sc.episodeCount(), 1);
    }

    // -------------------------------------------------------------------------
    // helpers
    // -------------------------------------------------------------------------

    function _addAs(address who, string memory name) internal returns (bytes32) {
        vm.prank(who);
        return sc.addEpisode(name, address(0), "ipfs://x", "2026-01-01");
    }

    function _goLiveAs(address who, string memory name) internal returns (bytes32) {
        vm.prank(who);
        return sc.goLive(name, address(0), "ipfs://x", "2026-01-01");
    }
}
