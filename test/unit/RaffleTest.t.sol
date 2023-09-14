// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;
import {DeployRaffle} from "../../script/DeployRaffle.s.sol";
import {Raffle} from "../../src/Raffle.sol";
import {Test, console} from "forge-std/Test.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {Vm} from "forge-std/Vm.sol";
import {VRFCoordinatorV2Mock} from "@chainlink/contracts/src/v0.8/mocks/VRFCoordinatorV2Mock.sol";

contract RaffleTest is Test {
    Raffle raffle;
    HelperConfig helperConfig;
    uint256 entranceFee;
    uint256 interval;
    address vrfCoordinator;
    bytes32 gasLane;
    uint64 subscriptionId;
    uint32 callbackGasLimit;
    uint256 deployerKey;
    address link;

    address public PLAYER = makeAddr("player");
    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    /*EVENTS*/
    event EnteredRaffle(address indexed player);
    /*MODIFIERS*/
    modifier raffleEnterAndTimePassed() {
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);
        _;
    }

    function setUp() external {
        DeployRaffle deployer = new DeployRaffle();
        (raffle, helperConfig) = deployer.run();
        (
            entranceFee,
            interval,
            vrfCoordinator,
            gasLane,
            subscriptionId,
            callbackGasLimit,
            link,

        ) = helperConfig.activeNetworkConfig();
        vm.deal(PLAYER, STARTING_USER_BALANCE);
    }

    function testRaffleInitializesInOpenState() public view {
        assert(raffle.getRaffleState() == Raffle.RaffleState.OPEN);
    }

    /////////////////
    // enterRaffle //
    /////////////////

    function testRaffleRevertsWhenYouDontPayEnough() public {
        //arrange
        vm.prank(PLAYER);
        //act / assert
        vm.expectRevert(Raffle.Raffle__NotEnoughETHSent.selector);
        raffle.enterRaffle();
    }

    function testCantEnterWhenRaffleIsCalculating()
        public
        raffleEnterAndTimePassed
    {
        raffle.performUpkeep("");

        vm.expectRevert(Raffle.Raffle__RaffleNotOpen.selector);
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
    }

    function testRaffleRecordsPlayerWhenTheyEnter() public {
        vm.prank(PLAYER);

        raffle.enterRaffle{value: entranceFee}();
        address playerRecorded = raffle.getPlayer(0);
        assert(playerRecorded == PLAYER);
    }

    function testEmitsEventOnEntrance() public {
        vm.prank(PLAYER);
        vm.expectEmit(true, false, false, false, address(raffle));
        emit EnteredRaffle(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
    }

    /////////////////
    // checkUpkeep //
    /////////////////

    function testCheckUpkeepReturnsFalseIfItHasNoBalance() public {
        //arrange
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);
        //act
        (bool upkeepNeeded, ) = raffle.checkUpkeep("");
        //assert
        assert(!upkeepNeeded);
    }

    function testCheckUpkeepReturnsFalseIfItRaffleNotOpen()
        public
        raffleEnterAndTimePassed
    {
        //arrange

        raffle.performUpkeep("");
        //act
        (bool upkeepNeeded, ) = raffle.checkUpkeep("");
        //assert
        assert(!upkeepNeeded);
    }

    function testCheckUpkeepReturnsFalseIfEnoughTimeHasntPassed() public {
        //arrange
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        vm.roll(block.number + 1);
        //act
        (bool upkeepNeeded, ) = raffle.checkUpkeep("");
        //assert
        assert(!upkeepNeeded);
    }

    function testCheckUpkeepReturnsTrueIfParametersAreGood()
        public
        raffleEnterAndTimePassed
    {
        //arrange

        //act
        (bool upkeepNeeded, ) = raffle.checkUpkeep("");
        //assert
        assert(upkeepNeeded);
    }

    ///////////////////
    // performUpkeep //
    ///////////////////

    function testPerformUpkeepCanOnlyRunIfCheckUpkeepIsTrue()
        public
        raffleEnterAndTimePassed
    {
        //act/assert
        raffle.performUpkeep("");
    }

    function testPerformUpkeepRevertsIfCheckUpkeepIsFalse() public {
        //arrange
        uint256 currentBalance = 0;
        uint256 numPlayers = 0;
        Raffle.RaffleState raffleState = raffle.getRaffleState();

        //act / assert
        vm.expectRevert(
            abi.encodeWithSelector(
                Raffle.Raffle__UpkeepNotNeeded.selector,
                currentBalance,
                numPlayers,
                raffleState
            )
        );
        raffle.performUpkeep("");
    }

    function testPerformUpkeepUpdatesRaffleStateAndEmitsRequestId()
        public
        raffleEnterAndTimePassed
    {
        //act
        vm.recordLogs();
        raffle.performUpkeep(""); //emit requestId
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1];
        Raffle.RaffleState rState = raffle.getRaffleState();
        assert(uint256(requestId) > 0);
        assert(uint256(rState) == 1);
    }

    ////////////////////////
    // fulfillRandomWords //
    ////////////////////////
    modifier skipFork() {
        //if not anvil chainid
        if (block.chainid != 31337) {
            return;
        }
        _;
    }

    function testFulfillRandomWordsCanOnlyBeCalledAfterPerformUpkeep(
        uint256 randomRequestId
    ) public raffleEnterAndTimePassed skipFork {
        vm.expectRevert("nonexistent request");

        VRFCoordinatorV2Mock(vrfCoordinator).fulfillRandomWords(
            randomRequestId,
            address(raffle)
        );
    }

    function testFulfillRandomWordsPicksAWinnerResetsAndSendsMoney()
        public
        raffleEnterAndTimePassed
        skipFork
    {
        //arrange
        uint256 additionalEntrants = 5;
        uint256 startingIndex = 1;
        for (
            uint256 i = startingIndex;
            i < startingIndex + additionalEntrants;
            i++
        ) {
            address player = address(uint160(i));
            hoax(player, STARTING_USER_BALANCE);
            raffle.enterRaffle{value: entranceFee}();
        }
        uint256 prize = entranceFee * (additionalEntrants);
        vm.recordLogs();
        raffle.performUpkeep(""); //emit requestId
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1];
        uint256 previousTimeStamp = raffle.getLastTimeStamp();
        //pretend to be chainlink vrf to get random numbe and pick winner
        VRFCoordinatorV2Mock(vrfCoordinator).fulfillRandomWords(
            uint256(requestId),
            address(raffle)
        );
        //assert
        assert(uint256(raffle.getRaffleState()) == 0);
        assert(raffle.getRecentWinner() != address(0));
        assert(raffle.getLengthOfPlayers() == 0);
        assert(raffle.getLastTimeStamp() > previousTimeStamp);
        assert(
            raffle.getRecentWinner().balance == STARTING_USER_BALANCE + prize
        );
    }
}
