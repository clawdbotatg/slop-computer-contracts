// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { SlopComputer } from "../contracts/SlopComputer.sol";

contract SlopComputerTest is Test {
    SlopComputer internal sc;
    address internal owner = address(0xA76);
    address internal stranger = address(0xB0B);

    /// @dev Default datetime used by `_addAs` / `_goLiveAs` (2025-01-01 UTC).
    uint256 internal constant DT = 1_735_689_600;

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
        sc.addEpisode("ep", "ep-slug", "", "", address(0), DT);
    }

    function test_goLive_revertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        sc.goLive("ep", "ep-slug", "", "", address(0), DT);
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
        assertEq(ep.slug, "first");
        assertEq(ep.datetime, DT);
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
        bytes32 actual = _addAs(owner, "a");
        assertEq(sc.getId("a", DT), actual);
    }

    function test_getId_isDeterministic() public view {
        bytes32 once = sc.getId("a", 42);
        bytes32 twice = sc.getId("a", 42);
        assertEq(once, twice);
    }

    function test_getId_ignoresMutableFields() public {
        // slug, manifest, contractAddr are all mutable via setters, so they must
        // not be part of the id. Two episodes with the same (name, datetime)
        // collide regardless of the other fields (here distinguished by slug
        // so the slug-uniqueness check doesn't trip first).
        vm.prank(owner);
        sc.addEpisode("name", "first-slug", "", "ipfs://a", address(0xAAA), DT);
        bytes32 expected = sc.getId("name", DT);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SlopComputer.EpisodeAlreadyExists.selector, expected));
        sc.addEpisode("name", "second-slug", "", "ipfs://b", address(0xBBB), DT);
    }

    function test_getId_differsAcrossContractAddresses() public {
        SlopComputer other = new SlopComputer(owner);
        assertTrue(sc.getId("a", DT) != other.getId("a", DT));
    }

    function test_getId_differsByDatetime() public view {
        assertTrue(sc.getId("a", DT) != sc.getId("a", DT + 1));
    }

    function test_addEpisode_revertsOnDuplicateContent() public {
        _addAs(owner, "dup");
        bytes32 expected = sc.getId("dup", DT);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SlopComputer.EpisodeAlreadyExists.selector, expected));
        sc.addEpisode("dup", "different-slug", "", "ipfs://b", address(0), DT);
    }

    function test_addEpisode_duplicateContentReportsContentErrorEvenIfSlugAlsoReused() public {
        // Same (name, datetime) AND same slug — id-collision must fire first so
        // the caller sees the real cause, not a misleading SlugAlreadyTaken.
        _addAs(owner, "dup");
        bytes32 expected = sc.getId("dup", DT);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SlopComputer.EpisodeAlreadyExists.selector, expected));
        sc.addEpisode("dup", "dup", "", "ipfs://b", address(0), DT);
    }

    function test_addEpisode_canReuseIdAfterDelete() public {
        bytes32 id = _addAs(owner, "reused");
        vm.prank(owner);
        sc.deleteEpisode(id);
        bytes32 readded = _addAs(owner, "reused");
        assertEq(id, readded);
        assertEq(sc.episodeCount(), 1);
    }

    function test_addEpisode_emitsEvent() public {
        vm.recordLogs();
        vm.prank(owner);
        sc.addEpisode("hello", "hello-slug", "", "ipfs://abc", address(0xCAFE), DT);
        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertEq(entries.length, 1);
        assertEq(
            entries[0].topics[0],
            keccak256("EpisodeAdded(bytes32,string,string,string,string,address,uint256)")
        );
    }

    // -------------------------------------------------------------------------
    // slug — validation, uniqueness, lookup
    // -------------------------------------------------------------------------

    function test_addEpisode_indexesSlug() public {
        bytes32 id = _addAs(owner, "indexed");
        assertEq(sc.slugToId("indexed"), id);
    }

    function test_addEpisode_revertsOnDuplicateSlug() public {
        _addAs(owner, "first");
        vm.prank(owner);
        vm.expectRevert(SlopComputer.SlugAlreadyTaken.selector);
        // Same slug but different (name, datetime) so the id-collision check
        // wouldn't trip first — slug check has to.
        sc.addEpisode("different-name", "first", "", "", address(0), DT + 1);
    }

    function test_addEpisode_revertsOnEmptySlug() public {
        vm.prank(owner);
        vm.expectRevert(SlopComputer.SlugInvalid.selector);
        sc.addEpisode("ep", "", "", "", address(0), DT);
    }

    function test_addEpisode_revertsOnSlugWithUppercase() public {
        vm.prank(owner);
        vm.expectRevert(SlopComputer.SlugInvalid.selector);
        sc.addEpisode("ep", "Ep-One", "", "", address(0), DT);
    }

    function test_addEpisode_revertsOnSlugWithUnderscore() public {
        vm.prank(owner);
        vm.expectRevert(SlopComputer.SlugInvalid.selector);
        sc.addEpisode("ep", "ep_one", "", "", address(0), DT);
    }

    function test_addEpisode_revertsOnSlugWithSlash() public {
        vm.prank(owner);
        vm.expectRevert(SlopComputer.SlugInvalid.selector);
        sc.addEpisode("ep", "ep/one", "", "", address(0), DT);
    }

    function test_addEpisode_revertsOnSlugTooLong() public {
        vm.prank(owner);
        vm.expectRevert(SlopComputer.SlugInvalid.selector);
        // 65 'a's
        sc.addEpisode("ep", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "", "", address(0), DT);
    }

    function test_addEpisode_revertsOnLeadingDash() public {
        vm.prank(owner);
        vm.expectRevert(SlopComputer.SlugInvalid.selector);
        sc.addEpisode("ep", "-pilot", "", "", address(0), DT);
    }

    function test_addEpisode_revertsOnTrailingDash() public {
        vm.prank(owner);
        vm.expectRevert(SlopComputer.SlugInvalid.selector);
        sc.addEpisode("ep", "pilot-", "", "", address(0), DT);
    }

    function test_addEpisode_revertsOnAllDashSlug() public {
        vm.prank(owner);
        vm.expectRevert(SlopComputer.SlugInvalid.selector);
        sc.addEpisode("ep", "---", "", "", address(0), DT);
    }

    function test_addEpisode_acceptsInnerDoubleDash() public {
        vm.prank(owner);
        bytes32 id = sc.addEpisode("ep", "the--episode", "", "", address(0), DT);
        assertEq(sc.getEpisode(id).slug, "the--episode");
    }

    function test_addEpisode_acceptsSlugAtMaxLength() public {
        // 64 'a's
        string memory slug = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        vm.prank(owner);
        bytes32 id = sc.addEpisode("ep", slug, "", "", address(0), DT);
        assertEq(sc.getEpisode(id).slug, slug);
    }

    function test_addEpisode_acceptsDigitsAndDashes() public {
        vm.prank(owner);
        bytes32 id = sc.addEpisode("ep", "ep-001-pilot", "", "", address(0), DT);
        assertEq(sc.getEpisode(id).slug, "ep-001-pilot");
    }

    function test_getEpisodeBySlug_returnsMatchingEpisode() public {
        bytes32 id = _addAs(owner, "fetch-by-slug");
        SlopComputer.Episode memory ep = sc.getEpisodeBySlug("fetch-by-slug");
        assertEq(ep.id, id);
        assertEq(ep.slug, "fetch-by-slug");
    }

    function test_getEpisodeBySlug_revertsForUnknownSlug() public {
        vm.expectRevert(abi.encodeWithSelector(SlopComputer.SlugNotFound.selector, "never-existed"));
        sc.getEpisodeBySlug("never-existed");
    }

    function test_setSlug_updatesField() public {
        bytes32 id = _addAs(owner, "old");
        vm.prank(owner);
        sc.setSlug(id, "new");
        assertEq(sc.getEpisode(id).slug, "new");
    }

    function test_setSlug_updatesIndex() public {
        bytes32 id = _addAs(owner, "old");
        vm.prank(owner);
        sc.setSlug(id, "new");
        assertEq(sc.slugToId("new"), id);
        assertEq(sc.slugToId("old"), bytes32(0));
    }

    function test_setSlug_acceptsNoOpRename() public {
        bytes32 id = _addAs(owner, "same");
        vm.prank(owner);
        sc.setSlug(id, "same"); // should not revert
        assertEq(sc.slugToId("same"), id);
    }

    function test_setSlug_revertsOnCollision() public {
        _addAs(owner, "taken");
        bytes32 id = _addAs(owner, "other");
        vm.prank(owner);
        vm.expectRevert(SlopComputer.SlugAlreadyTaken.selector);
        sc.setSlug(id, "taken");
    }

    function test_setSlug_revertsOnInvalidSlug() public {
        bytes32 id = _addAs(owner, "ep");
        vm.prank(owner);
        vm.expectRevert(SlopComputer.SlugInvalid.selector);
        sc.setSlug(id, "Bad Slug");
    }

    function test_setSlug_revertsForNonOwner() public {
        bytes32 id = _addAs(owner, "ep");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        sc.setSlug(id, "renamed");
    }

    function test_setSlug_revertsForUnknownId() public {
        bytes32 fake = keccak256("nope");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SlopComputer.EpisodeNotFound.selector, fake));
        sc.setSlug(fake, "anything");
    }

    function test_delete_freesSlug() public {
        bytes32 id = _addAs(owner, "free-me");
        vm.prank(owner);
        sc.deleteEpisode(id);
        assertEq(sc.slugToId("free-me"), bytes32(0));

        // And the slug is reusable on a fresh add.
        bytes32 readded = _addAs(owner, "free-me");
        assertEq(sc.slugToId("free-me"), readded);
    }

    // -------------------------------------------------------------------------
    // setManifest — the live → recorded flow
    // -------------------------------------------------------------------------

    function test_setManifest_updatesField() public {
        bytes32 id = _addAs(owner, "ep");
        vm.prank(owner);
        sc.setManifest(id, "ipfs://recorded");
        assertEq(sc.getEpisode(id).manifest, "ipfs://recorded");
    }

    function test_setManifest_doesNotChangeId() public {
        bytes32 id = _addAs(owner, "ep");
        vm.prank(owner);
        sc.setManifest(id, "ipfs://anything");
        assertEq(sc.head(), id);
        assertEq(sc.getEpisode(id).id, id);
    }

    function test_setManifest_liveToRecordedFlow() public {
        // Go live with an empty manifest (audience plays HLS while live == id),
        // then publish the manifest at finalize time.
        vm.prank(owner);
        bytes32 id = sc.goLive("episode 1", "episode-1", "", "", address(0), DT);
        assertEq(sc.live(), id);
        assertEq(sc.getEpisode(id).manifest, "");

        vm.prank(owner);
        sc.goOffline();

        vm.prank(owner);
        sc.setManifest(id, "ipfs://QmManifest");

        SlopComputer.Episode memory ep = sc.getEpisode(id);
        assertEq(ep.manifest, "ipfs://QmManifest");
        assertEq(ep.id, id); // id stable across the whole flow
    }

    function test_setManifest_revertsForNonOwner() public {
        bytes32 id = _addAs(owner, "ep");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        sc.setManifest(id, "ipfs://nope");
    }

    function test_setManifest_revertsForUnknownId() public {
        bytes32 fake = keccak256("nope");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SlopComputer.EpisodeNotFound.selector, fake));
        sc.setManifest(fake, "ipfs://nope");
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
    // goLive / goOffline / setLive
    // -------------------------------------------------------------------------

    function test_goLive_setsLivePointer() public {
        bytes32 id = _goLiveAs(owner, "live-show");
        assertEq(sc.live(), id);
        assertEq(sc.head(), id);
        assertEq(sc.episodeCount(), 1);
    }

    function test_goLive_replacesPreviousLiveButKeepsOldEpisodeInList() public {
        bytes32 first = _goLiveAs(owner, "first");
        bytes32 second = _goLiveAs(owner, "second");
        assertEq(sc.live(), second);
        assertEq(sc.episodeCount(), 2);
        assertEq(sc.getEpisode(first).name, "first");
        assertEq(sc.getEpisode(first).nextId, bytes32(0));
        assertEq(sc.getEpisode(second).nextId, first);
    }

    function test_goOffline_clearsLive() public {
        bytes32 id = _goLiveAs(owner, "show");
        vm.prank(owner);
        sc.goOffline();
        assertEq(sc.live(), bytes32(0));
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

    function test_setLive_marksExistingEpisodeAsLive() public {
        bytes32 id = _addAs(owner, "show");
        assertEq(sc.live(), bytes32(0));
        vm.prank(owner);
        sc.setLive(id);
        assertEq(sc.live(), id);
    }

    function test_setLive_resumesAfterGoOffline() public {
        bytes32 id = _goLiveAs(owner, "stream");

        vm.prank(owner);
        sc.goOffline();
        assertEq(sc.live(), bytes32(0));

        vm.prank(owner);
        sc.setLive(id);
        assertEq(sc.live(), id);
        assertEq(sc.episodeCount(), 1); // no duplicate created
    }

    function test_setLive_replacesExistingLive() public {
        bytes32 a = _goLiveAs(owner, "a");
        bytes32 b = _addAs(owner, "b");
        assertEq(sc.live(), a);
        vm.prank(owner);
        sc.setLive(b);
        assertEq(sc.live(), b);
    }

    function test_setLive_revertsForNonOwner() public {
        bytes32 id = _addAs(owner, "ep");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        sc.setLive(id);
    }

    function test_setLive_revertsForUnknownId() public {
        bytes32 fake = keccak256("nope");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SlopComputer.EpisodeNotFound.selector, fake));
        sc.setLive(fake);
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
        bytes32[] memory ids = new bytes32[](7);
        ids[0] = _addAs(owner, "ep0");
        ids[1] = _addAs(owner, "ep1");
        ids[2] = _addAs(owner, "ep2");
        ids[3] = _addAs(owner, "ep3");
        ids[4] = _addAs(owner, "ep4");
        ids[5] = _addAs(owner, "ep5");
        ids[6] = _addAs(owner, "ep6");

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
    // latest() / liveEpisode()
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

    function test_liveEpisode_returnsZeroStructWhenOffline() public {
        _addAs(owner, "head");
        SlopComputer.Episode memory ep = sc.liveEpisode();
        assertEq(ep.id, bytes32(0));
        assertEq(ep.name, "");
    }

    function test_liveEpisode_returnsLiveStruct() public {
        bytes32 id = _goLiveAs(owner, "show");
        SlopComputer.Episode memory ep = sc.liveEpisode();
        assertEq(ep.id, id);
        assertEq(ep.name, "show");
    }

    function test_liveEpisode_clearsAfterGoOffline() public {
        _goLiveAs(owner, "show");
        vm.prank(owner);
        sc.goOffline();
        assertEq(sc.liveEpisode().id, bytes32(0));
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
        assertEq(sc.indexOf(a), 2);
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
        sc.addEpisode("post-handoff", "post-handoff", "", "", address(0), 0);
        assertEq(sc.episodeCount(), 1);
    }

    // -------------------------------------------------------------------------
    // addedAt + indexer-event additions
    // -------------------------------------------------------------------------

    function test_addedAt_isBlockTimestamp() public {
        vm.warp(1_800_000_000);
        bytes32 id = _addAs(owner, "ep0");
        assertEq(sc.getEpisode(id).addedAt, 1_800_000_000);
    }

    function test_addedAt_doesNotChangeWhenDatetimeIsFuture() public {
        // Show is scheduled for the future; addedAt should still be `now`.
        vm.warp(1_800_000_000);
        vm.prank(owner);
        bytes32 id = sc.addEpisode("future", "future", "", "", address(0), 1_900_000_000);
        SlopComputer.Episode memory ep = sc.getEpisode(id);
        assertEq(ep.datetime, 1_900_000_000);
        assertEq(ep.addedAt, 1_800_000_000);
    }

    function test_goLive_emitsWentLiveWithPreviousZeroAndResumedFalse() public {
        vm.expectEmit(true, true, false, true, address(sc));
        emit SlopComputer.WentLive(sc.getId("show", DT), bytes32(0), false);
        _goLiveAs(owner, "show");
    }

    function test_setLive_emitsWentLiveWithPreviousAndResumedTrue() public {
        bytes32 first = _goLiveAs(owner, "first");
        bytes32 second = _addAs(owner, "second");
        vm.expectEmit(true, true, false, true, address(sc));
        emit SlopComputer.WentLive(second, first, true);
        vm.prank(owner);
        sc.setLive(second);
    }

    function test_setLive_emitsPreviousZeroWhenResumingFromOffline() public {
        bytes32 id = _goLiveAs(owner, "show");
        vm.prank(owner);
        sc.goOffline();
        vm.expectEmit(true, true, false, true, address(sc));
        emit SlopComputer.WentLive(id, bytes32(0), true);
        vm.prank(owner);
        sc.setLive(id);
    }

    function test_setSlug_revertsWhenLiveEqualsId() public {
        bytes32 id = _goLiveAs(owner, "live-show");
        vm.expectRevert(abi.encodeWithSelector(SlopComputer.EpisodeIsLive.selector, id));
        vm.prank(owner);
        sc.setSlug(id, "renamed");
    }

    function test_setSlug_allowedAfterGoOffline() public {
        bytes32 id = _goLiveAs(owner, "live-show");
        vm.prank(owner);
        sc.goOffline();
        vm.prank(owner);
        sc.setSlug(id, "renamed");
        assertEq(sc.getEpisode(id).slug, "renamed");
    }

    function test_deleteEpisode_emitsWentOfflineWhenDeletingLive() public {
        bytes32 id = _goLiveAs(owner, "live-show");
        vm.expectEmit(true, false, false, true, address(sc));
        emit SlopComputer.WentOffline(id);
        vm.prank(owner);
        sc.deleteEpisode(id);
        assertEq(sc.live(), bytes32(0));
    }

    function test_deleteEpisode_doesNotEmitWentOfflineForNonLiveEpisode() public {
        bytes32 a = _goLiveAs(owner, "live-show");
        bytes32 b = _addAs(owner, "non-live");
        vm.recordLogs();
        vm.prank(owner);
        sc.deleteEpisode(b);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 wentOfflineTopic = keccak256("WentOffline(bytes32)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != wentOfflineTopic, "should not emit WentOffline for non-live delete");
        }
        // Sanity: live pointer still set to a.
        assertEq(sc.live(), a);
    }

    // -------------------------------------------------------------------------
    // liveSlug — decouples the on-chain `slug` from the relay-room slug so
    // one room can host multiple episodes
    // -------------------------------------------------------------------------

    function test_liveSlug_defaultsToEmpty() public {
        bytes32 id = _addAs(owner, "ep0");
        assertEq(sc.getEpisode(id).liveSlug, "");
    }

    function test_setLiveSlug_storesValue() public {
        bytes32 id = _addAs(owner, "ep0");
        vm.prank(owner);
        sc.setLiveSlug(id, "studio");
        assertEq(sc.getEpisode(id).liveSlug, "studio");
    }

    function test_setLiveSlug_allowsEmptyAsReset() public {
        bytes32 id = _addAs(owner, "ep0");
        vm.prank(owner);
        sc.setLiveSlug(id, "studio");
        vm.prank(owner);
        sc.setLiveSlug(id, "");
        assertEq(sc.getEpisode(id).liveSlug, "");
    }

    function test_setLiveSlug_revertsOnInvalidFormat() public {
        bytes32 id = _addAs(owner, "ep0");
        vm.expectRevert(SlopComputer.SlugInvalid.selector);
        vm.prank(owner);
        sc.setLiveSlug(id, "Bad Slug");
    }

    function test_setLiveSlug_revertsForUnknownId() public {
        bytes32 fake = keccak256("nope");
        vm.expectRevert(abi.encodeWithSelector(SlopComputer.EpisodeNotFound.selector, fake));
        vm.prank(owner);
        sc.setLiveSlug(fake, "studio");
    }

    function test_setLiveSlug_revertsForNonOwner() public {
        bytes32 id = _addAs(owner, "ep0");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        sc.setLiveSlug(id, "studio");
    }

    function test_setLiveSlug_emitsEvent() public {
        bytes32 id = _addAs(owner, "ep0");
        vm.expectEmit(true, false, false, true, address(sc));
        emit SlopComputer.EpisodeLiveSlugSet(id, "studio");
        vm.prank(owner);
        sc.setLiveSlug(id, "studio");
    }

    function test_setLiveSlug_sameValueAcrossEpisodes() public {
        // Many-to-one: a single studio room can back multiple episodes.
        bytes32 a = _addAs(owner, "first");
        bytes32 b = _addAs(owner, "second");
        vm.prank(owner);
        sc.setLiveSlug(a, "studio");
        vm.prank(owner);
        sc.setLiveSlug(b, "studio");
        assertEq(sc.getEpisode(a).liveSlug, "studio");
        assertEq(sc.getEpisode(b).liveSlug, "studio");
    }

    // -------------------------------------------------------------------------
    // setName — ENS primary name via the ReverseRegistrar
    // -------------------------------------------------------------------------

    function test_setName_callsReverseRegistrarAsThisContract() public {
        MockReverseRegistrar mock = new MockReverseRegistrar();
        vm.etch(sc.ENS_REVERSE_REGISTRAR(), address(mock).code);

        vm.prank(owner);
        bytes32 node = sc.setName("slopcomputer.eth");

        MockReverseRegistrar reg = MockReverseRegistrar(sc.ENS_REVERSE_REGISTRAR());
        assertEq(reg.lastName(), "slopcomputer.eth");
        assertEq(reg.lastCaller(), address(sc)); // the contract, not the owner
        assertEq(node, mock.NODE());
    }

    function test_setName_emitsNameSet() public {
        MockReverseRegistrar mock = new MockReverseRegistrar();
        vm.etch(sc.ENS_REVERSE_REGISTRAR(), address(mock).code);

        vm.expectEmit(false, false, false, true, address(sc));
        emit SlopComputer.NameSet("slopcomputer.eth", mock.NODE());
        vm.prank(owner);
        sc.setName("slopcomputer.eth");
    }

    function test_setName_revertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        sc.setName("slopcomputer.eth");
    }

    // -------------------------------------------------------------------------
    // execute — owner recovery / admin escape hatch
    // -------------------------------------------------------------------------

    function test_execute_recoversEth() public {
        vm.deal(address(sc), 1 ether);
        address to = address(0xD00D);
        vm.prank(owner);
        sc.execute(to, 1 ether, "");
        assertEq(to.balance, 1 ether);
        assertEq(address(sc).balance, 0);
    }

    function test_execute_recoversErc20() public {
        MockERC20 token = new MockERC20();
        token.mint(address(sc), 500);
        address recipient = address(0xBEEF);

        vm.prank(owner);
        sc.execute(address(token), 0, abi.encodeWithSignature("transfer(address,uint256)", recipient, uint256(500)));

        assertEq(token.balanceOf(recipient), 500);
        assertEq(token.balanceOf(address(sc)), 0);
    }

    function test_execute_returnsCalleeReturnData() public {
        MockERC20 token = new MockERC20();
        token.mint(address(sc), 10);
        vm.prank(owner);
        bytes memory ret =
            sc.execute(address(token), 0, abi.encodeWithSignature("transfer(address,uint256)", address(0xBEEF), uint256(10)));
        assertTrue(abi.decode(ret, (bool)));
    }

    function test_execute_forwardsAttachedValue() public {
        address to = address(0xD00D);
        vm.deal(owner, 2 ether);
        vm.prank(owner);
        sc.execute{ value: 1 ether }(to, 1 ether, "");
        assertEq(to.balance, 1 ether);
    }

    function test_execute_bubblesRevertReason() public {
        Reverter r = new Reverter();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Reverter.Boom.selector, "nope"));
        sc.execute(address(r), 0, abi.encodeWithSignature("boom()"));
    }

    function test_execute_emitsExecuted() public {
        vm.deal(address(sc), 1 ether);
        address to = address(0xD00D);
        vm.expectEmit(true, false, false, true, address(sc));
        emit SlopComputer.Executed(to, 1 ether, "");
        vm.prank(owner);
        sc.execute(to, 1 ether, "");
    }

    function test_execute_revertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        sc.execute(address(0xBEEF), 0, "");
    }

    // -------------------------------------------------------------------------
    // helpers — uses `name` as the slug too for brevity (slugs are validated
    // a-z 0-9 -, so test names like "a", "b", "ep0", "first" pass through)
    // -------------------------------------------------------------------------

    function _addAs(address who, string memory name) internal returns (bytes32) {
        vm.prank(who);
        return sc.addEpisode(name, name, "", "", address(0), DT);
    }

    function _goLiveAs(address who, string memory name) internal returns (bytes32) {
        vm.prank(who);
        return sc.goLive(name, name, "", "", address(0), DT);
    }
}

// -----------------------------------------------------------------------------
// test mocks
// -----------------------------------------------------------------------------

/// @dev Stand-in for the ENS ReverseRegistrar, etched over the real address so
///      `setName` has code to call. Records the name and the caller it saw.
contract MockReverseRegistrar {
    string public lastName;
    address public lastCaller;
    bytes32 public constant NODE = keccak256("addr.reverse-node");

    function setName(string memory name) external returns (bytes32) {
        lastName = name;
        lastCaller = msg.sender;
        return NODE;
    }
}

/// @dev Minimal ERC-20-shaped token for exercising `execute`-based recovery.
contract MockERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Reverts with a custom error so we can assert `execute` bubbles it up.
contract Reverter {
    error Boom(string why);

    function boom() external pure {
        revert Boom("nope");
    }
}
