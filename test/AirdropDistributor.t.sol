// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {AirdropDistributor, IVoteSalePool, IKickoffFactory, IProjectTokenFactory} from "../src/AirdropDistributor.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

/*//////////////////////////////////////////////////////////////
                          MOCK CONTRACTS
//////////////////////////////////////////////////////////////*/

contract MockERC20 {
    string public name = "MockToken";
    string public symbol = "MTK";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

contract MockVoteSalePool {
    IVoteSalePool.PoolState public state;

    function setState(IVoteSalePool.PoolState _state) external {
        state = _state;
    }
}

contract MockKickoffFactory {
    mapping(address => address) public poolByToken;

    function setPoolByToken(address token, address pool) external {
        poolByToken[token] = pool;
    }
}

contract MockProjectTokenFactory {
    struct TokenInfo {
        address token;
        string name;
        string symbol;
        uint256 totalSupply;
        address creator;
        uint256 createdAt;
    }

    mapping(address => TokenInfo) internal _tokenInfo;

    function setTokenInfo(address token, address creator) external {
        _tokenInfo[token] = TokenInfo({
            token: token,
            name: "Mock",
            symbol: "MCK",
            totalSupply: 1_000_000 ether,
            creator: creator,
            createdAt: block.timestamp
        });
    }

    function tokenInfo(address token)
        external
        view
        returns (address, string memory, string memory, uint256, address, uint256)
    {
        TokenInfo memory info = _tokenInfo[token];
        return (info.token, info.name, info.symbol, info.totalSupply, info.creator, info.createdAt);
    }
}

/*//////////////////////////////////////////////////////////////
                         MERKLE HELPERS
//////////////////////////////////////////////////////////////*/

/// @dev Builds a simple Merkle tree from double-hashed leaves (OZ StandardMerkleTree compatible)
library MerkleHelper {
    function hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    /// @dev Builds a Merkle tree and returns (root, proofs[]) for leaves[].
    ///      Supports up to 8 leaves. Pads to next power of 2 with zero hashes.
    function buildTree(bytes32[] memory leaves)
        internal
        pure
        returns (bytes32 root, bytes32[][] memory proofs)
    {
        uint256 n = leaves.length;
        require(n > 0 && n <= 8, "1-8 leaves only");

        uint256 size = 1;
        while (size < n) size *= 2;

        bytes32[] memory layer = new bytes32[](size);
        for (uint256 i = 0; i < size; i++) {
            layer[i] = i < n ? leaves[i] : bytes32(0);
        }

        uint256 depth = 0;
        {
            uint256 s = size;
            while (s > 1) { depth++; s /= 2; }
        }

        bytes32[][] memory layers = new bytes32[][](depth + 1);
        layers[0] = layer;

        for (uint256 d = 0; d < depth; d++) {
            uint256 len = layers[d].length / 2;
            bytes32[] memory nextLayer = new bytes32[](len);
            for (uint256 i = 0; i < len; i++) {
                nextLayer[i] = hashPair(layers[d][2 * i], layers[d][2 * i + 1]);
            }
            layers[d + 1] = nextLayer;
        }

        root = layers[depth][0];

        proofs = new bytes32[][](n);
        for (uint256 i = 0; i < n; i++) {
            bytes32[] memory proof = new bytes32[](depth);
            uint256 idx = i;
            for (uint256 d = 0; d < depth; d++) {
                uint256 siblingIdx = idx % 2 == 0 ? idx + 1 : idx - 1;
                proof[d] = layers[d][siblingIdx];
                idx /= 2;
            }
            proofs[i] = proof;
        }
    }
}

/*//////////////////////////////////////////////////////////////
                         TEST CONTRACT
//////////////////////////////////////////////////////////////*/

contract AirdropDistributorTest is Test {
    using MerkleHelper for bytes32[];

    AirdropDistributor distributor;
    MockERC20 token;
    MockVoteSalePool pool;
    MockKickoffFactory factory;
    MockProjectTokenFactory tokenFactory;

    address admin = address(this);
    address projectOwner = address(0x1111);
    address user1 = address(0x2222);
    address user2 = address(0x3333);
    address user3 = address(0x4444);

    uint256 constant AMOUNT_1 = 1000 ether;
    uint256 constant AMOUNT_2 = 2000 ether;
    uint256 constant AMOUNT_3 = 500 ether;
    uint256 constant TOTAL = AMOUNT_1 + AMOUNT_2 + AMOUNT_3;

    bytes32 merkleRoot;
    bytes32[][] proofs;

    /// @dev Double-hash leaf matching AirdropDistributor.claim() and OZ StandardMerkleTree
    function _leaf(address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, amount))));
    }

    function setUp() public {
        factory = new MockKickoffFactory();
        tokenFactory = new MockProjectTokenFactory();
        distributor = new AirdropDistributor(address(factory), address(tokenFactory));
        token = new MockERC20();
        pool = new MockVoteSalePool();

        // Register pool in mock factory
        factory.setPoolByToken(address(token), address(pool));

        // Register token creator in mock token factory
        tokenFactory.setTokenInfo(address(token), projectOwner);

        // Build Merkle tree with double-hashed leaves
        bytes32[] memory leaves = new bytes32[](3);
        leaves[0] = _leaf(user1, AMOUNT_1);
        leaves[1] = _leaf(user2, AMOUNT_2);
        leaves[2] = _leaf(user3, AMOUNT_3);
        (merkleRoot, proofs) = leaves.buildTree();

        // Mint tokens to distributor
        token.mint(address(distributor), TOTAL);
    }

    /*//////////////////////////////////////////////////////////////
                       CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_constructor() public view {
        assertEq(distributor.owner(), admin);
        assertEq(address(distributor.kickoffFactory()), address(factory));
        assertEq(address(distributor.projectTokenFactory()), address(tokenFactory));
    }

    function test_constructor_revert_zeroFactory() public {
        vm.expectRevert(abi.encodeWithSelector(AirdropDistributor.ZeroAddress.selector));
        new AirdropDistributor(address(0), address(tokenFactory));
    }

    function test_constructor_revert_zeroTokenFactory() public {
        vm.expectRevert(abi.encodeWithSelector(AirdropDistributor.ZeroAddress.selector));
        new AirdropDistributor(address(factory), address(0));
    }

    /*//////////////////////////////////////////////////////////////
                      CREATE AIRDROP TESTS
    //////////////////////////////////////////////////////////////*/

    function test_createAirdrop() public {
        vm.prank(projectOwner);
        distributor.createAirdrop(address(token), address(pool), merkleRoot, TOTAL, "QmTest123");

        AirdropDistributor.AirdropConfig memory config = distributor.getAirdrop(address(token));
        assertEq(config.projectOwner, projectOwner);
        assertEq(config.voteSalePool, address(pool));
        assertEq(config.merkleRoot, merkleRoot);
        assertEq(config.totalAllocation, TOTAL);
        assertEq(config.totalClaimed, 0);
        assertTrue(config.active);
        assertEq(keccak256(bytes(config.ipfsHash)), keccak256(bytes("QmTest123")));
    }

    function test_createAirdrop_revert_zeroToken() public {
        vm.expectRevert(abi.encodeWithSelector(AirdropDistributor.ZeroAddress.selector));
        distributor.createAirdrop(address(0), address(pool), merkleRoot, TOTAL, "QmTest123");
    }

    function test_createAirdrop_revert_zeroPool() public {
        vm.expectRevert(abi.encodeWithSelector(AirdropDistributor.ZeroAddress.selector));
        distributor.createAirdrop(address(token), address(0), merkleRoot, TOTAL, "QmTest123");
    }

    function test_createAirdrop_revert_zeroAllocation() public {
        vm.expectRevert(abi.encodeWithSelector(AirdropDistributor.ZeroAmount.selector));
        vm.prank(projectOwner);
        distributor.createAirdrop(address(token), address(pool), merkleRoot, 0, "QmTest123");
    }

    function test_createAirdrop_revert_zeroRoot() public {
        vm.expectRevert(abi.encodeWithSelector(AirdropDistributor.ZeroAmount.selector));
        vm.prank(projectOwner);
        distributor.createAirdrop(address(token), address(pool), bytes32(0), TOTAL, "QmTest123");
    }

    function test_createAirdrop_revert_alreadyExists() public {
        vm.prank(projectOwner);
        distributor.createAirdrop(address(token), address(pool), merkleRoot, TOTAL, "QmTest123");

        vm.expectRevert(abi.encodeWithSelector(AirdropDistributor.AirdropAlreadyExists.selector));
        vm.prank(projectOwner);
        distributor.createAirdrop(address(token), address(pool), merkleRoot, TOTAL, "QmTest123");
    }

    function test_createAirdrop_revert_notTokenCreator() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(AirdropDistributor.NotTokenCreator.selector));
        distributor.createAirdrop(address(token), address(pool), merkleRoot, TOTAL, "QmTest123");
    }

    function test_createAirdrop_revert_unregisteredToken() public {
        MockERC20 unknownToken = new MockERC20();
        unknownToken.mint(address(distributor), TOTAL);

        // Token not registered in ProjectTokenFactory — creator is address(0)
        vm.prank(projectOwner);
        vm.expectRevert(abi.encodeWithSelector(AirdropDistributor.NotTokenCreator.selector));
        distributor.createAirdrop(address(unknownToken), address(pool), merkleRoot, TOTAL, "QmTest123");
    }

    function test_createAirdrop_revert_poolNotLinked() public {
        MockVoteSalePool fakePool = new MockVoteSalePool();
        vm.prank(projectOwner);
        vm.expectRevert(abi.encodeWithSelector(AirdropDistributor.PoolNotLinked.selector));
        distributor.createAirdrop(address(token), address(fakePool), merkleRoot, TOTAL, "QmTest123");
    }

    function test_createAirdrop_revert_insufficientBalance() public {
        vm.prank(projectOwner);
        vm.expectRevert(abi.encodeWithSelector(AirdropDistributor.InsufficientBalance.selector));
        distributor.createAirdrop(address(token), address(pool), merkleRoot, TOTAL + 1, "QmTest123");
    }

    /*//////////////////////////////////////////////////////////////
                     UPDATE MERKLE ROOT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_updateMerkleRoot() public {
        vm.prank(projectOwner);
        distributor.createAirdrop(address(token), address(pool), merkleRoot, TOTAL, "QmTest123");

        bytes32 newRoot = keccak256("newRoot");
        vm.prank(projectOwner);
        distributor.updateMerkleRoot(address(token), newRoot, "QmNewHash");

        AirdropDistributor.AirdropConfig memory config = distributor.getAirdrop(address(token));
        assertEq(config.merkleRoot, newRoot);
        assertEq(keccak256(bytes(config.ipfsHash)), keccak256(bytes("QmNewHash")));
    }

    function test_updateMerkleRoot_revert_notActive() public {
        bytes32 newRoot = keccak256("newRoot");
        vm.expectRevert(abi.encodeWithSelector(AirdropDistributor.AirdropNotFound.selector));
        distributor.updateMerkleRoot(address(token), newRoot, "QmNewHash");
    }

    function test_updateMerkleRoot_revert_notProjectOwner() public {
        vm.prank(projectOwner);
        distributor.createAirdrop(address(token), address(pool), merkleRoot, TOTAL, "QmTest123");

        bytes32 newRoot = keccak256("newRoot");
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(AirdropDistributor.NotProjectOwner.selector));
        distributor.updateMerkleRoot(address(token), newRoot, "QmNewHash");
    }

    function test_updateMerkleRoot_revert_zeroRoot() public {
        vm.prank(projectOwner);
        distributor.createAirdrop(address(token), address(pool), merkleRoot, TOTAL, "QmTest123");

        vm.prank(projectOwner);
        vm.expectRevert(abi.encodeWithSelector(AirdropDistributor.ZeroAmount.selector));
        distributor.updateMerkleRoot(address(token), bytes32(0), "QmNewHash");
    }

    function test_updateMerkleRoot_revert_poolCompleted() public {
        vm.prank(projectOwner);
        distributor.createAirdrop(address(token), address(pool), merkleRoot, TOTAL, "QmTest123");

        pool.setState(IVoteSalePool.PoolState.Completed);

        bytes32 newRoot = keccak256("newRoot");
        vm.prank(projectOwner);
        vm.expectRevert(abi.encodeWithSelector(AirdropDistributor.ClaimsAlreadyStarted.selector));
        distributor.updateMerkleRoot(address(token), newRoot, "QmNewHash");
    }

    /*//////////////////////////////////////////////////////////////
                          CLAIM TESTS
    //////////////////////////////////////////////////////////////*/

    function _setupAirdropCompleted() internal {
        vm.prank(projectOwner);
        distributor.createAirdrop(address(token), address(pool), merkleRoot, TOTAL, "QmTest123");
        pool.setState(IVoteSalePool.PoolState.Completed);
    }

    function test_claim_user1() public {
        _setupAirdropCompleted();

        vm.prank(user1);
        distributor.claim(address(token), AMOUNT_1, proofs[0]);

        assertEq(token.balanceOf(user1), AMOUNT_1);
        assertTrue(distributor.hasClaimed(address(token), user1));

        AirdropDistributor.AirdropConfig memory config = distributor.getAirdrop(address(token));
        assertEq(config.totalClaimed, AMOUNT_1);
    }

    function test_claim_user2() public {
        _setupAirdropCompleted();

        vm.prank(user2);
        distributor.claim(address(token), AMOUNT_2, proofs[1]);

        assertEq(token.balanceOf(user2), AMOUNT_2);
        assertTrue(distributor.hasClaimed(address(token), user2));
    }

    function test_claim_allUsers() public {
        _setupAirdropCompleted();

        vm.prank(user1);
        distributor.claim(address(token), AMOUNT_1, proofs[0]);

        vm.prank(user2);
        distributor.claim(address(token), AMOUNT_2, proofs[1]);

        vm.prank(user3);
        distributor.claim(address(token), AMOUNT_3, proofs[2]);

        assertEq(token.balanceOf(user1), AMOUNT_1);
        assertEq(token.balanceOf(user2), AMOUNT_2);
        assertEq(token.balanceOf(user3), AMOUNT_3);

        AirdropDistributor.AirdropConfig memory config = distributor.getAirdrop(address(token));
        assertEq(config.totalClaimed, TOTAL);
        assertEq(token.balanceOf(address(distributor)), 0);
    }

    function test_claim_revert_notActive() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(AirdropDistributor.AirdropNotActive.selector));
        distributor.claim(address(token), AMOUNT_1, proofs[0]);
    }

    function test_claim_revert_alreadyClaimed() public {
        _setupAirdropCompleted();

        vm.prank(user1);
        distributor.claim(address(token), AMOUNT_1, proofs[0]);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(AirdropDistributor.AlreadyClaimed.selector));
        distributor.claim(address(token), AMOUNT_1, proofs[0]);
    }

    function test_claim_revert_poolNotCompleted() public {
        vm.prank(projectOwner);
        distributor.createAirdrop(address(token), address(pool), merkleRoot, TOTAL, "QmTest123");

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(AirdropDistributor.PoolNotCompleted.selector));
        distributor.claim(address(token), AMOUNT_1, proofs[0]);
    }

    function test_claim_revert_poolVoting() public {
        vm.prank(projectOwner);
        distributor.createAirdrop(address(token), address(pool), merkleRoot, TOTAL, "QmTest123");
        pool.setState(IVoteSalePool.PoolState.Voting);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(AirdropDistributor.PoolNotCompleted.selector));
        distributor.claim(address(token), AMOUNT_1, proofs[0]);
    }

    function test_claim_revert_invalidProof() public {
        _setupAirdropCompleted();

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(AirdropDistributor.InvalidProof.selector));
        distributor.claim(address(token), AMOUNT_1, proofs[1]);
    }

    function test_claim_revert_wrongAmount() public {
        _setupAirdropCompleted();

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(AirdropDistributor.InvalidProof.selector));
        distributor.claim(address(token), AMOUNT_2, proofs[0]);
    }

    /*//////////////////////////////////////////////////////////////
                       WITHDRAWAL TESTS
    //////////////////////////////////////////////////////////////*/

    function _setupAirdropForWithdraw() internal {
        vm.prank(projectOwner);
        distributor.createAirdrop(address(token), address(pool), merkleRoot, TOTAL, "QmTest123");
    }

    function test_fullWithdrawFlow() public {
        _setupAirdropForWithdraw();

        address recipient = address(0x9999);
        uint256 withdrawAmount = 500 ether;

        vm.prank(projectOwner);
        distributor.requestWithdraw(address(token), recipient, withdrawAmount);

        AirdropDistributor.WithdrawRequest memory req = distributor.getWithdrawRequest(address(token));
        assertEq(req.to, recipient);
        assertEq(req.amount, withdrawAmount);
        assertTrue(req.pending);
        assertFalse(req.approved);

        distributor.approveWithdraw(address(token));

        req = distributor.getWithdrawRequest(address(token));
        assertTrue(req.approved);

        vm.prank(projectOwner);
        distributor.executeWithdraw(address(token));

        assertEq(token.balanceOf(recipient), withdrawAmount);

        req = distributor.getWithdrawRequest(address(token));
        assertFalse(req.pending);
    }

    function test_requestWithdraw_revert_notActive() public {
        vm.expectRevert(abi.encodeWithSelector(AirdropDistributor.AirdropNotFound.selector));
        vm.prank(projectOwner);
        distributor.requestWithdraw(address(token), address(0x9999), 100 ether);
    }

    function test_requestWithdraw_revert_notProjectOwner() public {
        _setupAirdropForWithdraw();

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(AirdropDistributor.NotProjectOwner.selector));
        distributor.requestWithdraw(address(token), address(0x9999), 100 ether);
    }

    function test_requestWithdraw_revert_zeroAddress() public {
        _setupAirdropForWithdraw();

        vm.prank(projectOwner);
        vm.expectRevert(abi.encodeWithSelector(AirdropDistributor.ZeroAddress.selector));
        distributor.requestWithdraw(address(token), address(0), 100 ether);
    }

    function test_requestWithdraw_revert_zeroAmount() public {
        _setupAirdropForWithdraw();

        vm.prank(projectOwner);
        vm.expectRevert(abi.encodeWithSelector(AirdropDistributor.ZeroAmount.selector));
        distributor.requestWithdraw(address(token), address(0x9999), 0);
    }

    function test_requestWithdraw_revert_alreadyPending() public {
        _setupAirdropForWithdraw();

        vm.prank(projectOwner);
        distributor.requestWithdraw(address(token), address(0x9999), 100 ether);

        vm.prank(projectOwner);
        vm.expectRevert(abi.encodeWithSelector(AirdropDistributor.WithdrawAlreadyPending.selector));
        distributor.requestWithdraw(address(token), address(0x8888), 200 ether);
    }

    function test_requestWithdraw_revert_insufficientBalance() public {
        _setupAirdropForWithdraw();

        vm.prank(projectOwner);
        vm.expectRevert(abi.encodeWithSelector(AirdropDistributor.InsufficientBalance.selector));
        distributor.requestWithdraw(address(token), address(0x9999), TOTAL + 1);
    }

    function test_approveWithdraw_revert_notOwner() public {
        _setupAirdropForWithdraw();

        vm.prank(projectOwner);
        distributor.requestWithdraw(address(token), address(0x9999), 100 ether);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(AirdropDistributor.NotOwner.selector));
        distributor.approveWithdraw(address(token));
    }

    function test_approveWithdraw_revert_notRequested() public {
        vm.expectRevert(abi.encodeWithSelector(AirdropDistributor.WithdrawNotRequested.selector));
        distributor.approveWithdraw(address(token));
    }

    function test_executeWithdraw_revert_notProjectOwner() public {
        _setupAirdropForWithdraw();

        vm.prank(projectOwner);
        distributor.requestWithdraw(address(token), address(0x9999), 100 ether);
        distributor.approveWithdraw(address(token));

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(AirdropDistributor.NotProjectOwner.selector));
        distributor.executeWithdraw(address(token));
    }

    function test_executeWithdraw_revert_notApproved() public {
        _setupAirdropForWithdraw();

        vm.prank(projectOwner);
        distributor.requestWithdraw(address(token), address(0x9999), 100 ether);

        vm.prank(projectOwner);
        vm.expectRevert(abi.encodeWithSelector(AirdropDistributor.WithdrawNotApproved.selector));
        distributor.executeWithdraw(address(token));
    }

    function test_executeWithdraw_revert_notRequested() public {
        _setupAirdropForWithdraw();

        vm.prank(projectOwner);
        vm.expectRevert(abi.encodeWithSelector(AirdropDistributor.WithdrawNotRequested.selector));
        distributor.executeWithdraw(address(token));
    }

    function test_executeWithdraw_revert_insufficientBalance() public {
        _setupAirdropCompleted();

        // Request withdraw for full amount
        vm.prank(projectOwner);
        distributor.requestWithdraw(address(token), address(0x9999), TOTAL);

        distributor.approveWithdraw(address(token));

        // Users claim most tokens between request and execute
        vm.prank(user1);
        distributor.claim(address(token), AMOUNT_1, proofs[0]);
        vm.prank(user2);
        distributor.claim(address(token), AMOUNT_2, proofs[1]);

        // Execute should now revert — balance decreased due to claims
        vm.prank(projectOwner);
        vm.expectRevert(abi.encodeWithSelector(AirdropDistributor.InsufficientBalance.selector));
        distributor.executeWithdraw(address(token));
    }

    function test_cancelWithdraw() public {
        _setupAirdropForWithdraw();

        vm.prank(projectOwner);
        distributor.requestWithdraw(address(token), address(0x9999), 100 ether);

        vm.prank(projectOwner);
        distributor.cancelWithdraw(address(token));

        AirdropDistributor.WithdrawRequest memory req = distributor.getWithdrawRequest(address(token));
        assertFalse(req.pending);
    }

    function test_cancelWithdraw_revert_notProjectOwner() public {
        _setupAirdropForWithdraw();

        vm.prank(projectOwner);
        distributor.requestWithdraw(address(token), address(0x9999), 100 ether);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(AirdropDistributor.NotProjectOwner.selector));
        distributor.cancelWithdraw(address(token));
    }

    function test_cancelWithdraw_revert_notRequested() public {
        _setupAirdropForWithdraw();

        vm.prank(projectOwner);
        vm.expectRevert(abi.encodeWithSelector(AirdropDistributor.WithdrawNotRequested.selector));
        distributor.cancelWithdraw(address(token));
    }

    function test_withdrawAfterCancel_canRequestAgain() public {
        _setupAirdropForWithdraw();

        vm.prank(projectOwner);
        distributor.requestWithdraw(address(token), address(0x9999), 100 ether);

        vm.prank(projectOwner);
        distributor.cancelWithdraw(address(token));

        vm.prank(projectOwner);
        distributor.requestWithdraw(address(token), address(0x8888), 200 ether);

        AirdropDistributor.WithdrawRequest memory req = distributor.getWithdrawRequest(address(token));
        assertEq(req.to, address(0x8888));
        assertEq(req.amount, 200 ether);
        assertTrue(req.pending);
    }

    /*//////////////////////////////////////////////////////////////
                      OWNERSHIP TESTS
    //////////////////////////////////////////////////////////////*/

    function test_transferOwnership() public {
        address newOwner = address(0x5555);

        distributor.transferOwnership(newOwner);
        assertEq(distributor.pendingOwner(), newOwner);

        assertEq(distributor.owner(), admin);

        vm.prank(newOwner);
        distributor.acceptOwnership();

        assertEq(distributor.owner(), newOwner);
        assertEq(distributor.pendingOwner(), address(0));
    }

    function test_transferOwnership_revert_notOwner() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(AirdropDistributor.NotOwner.selector));
        distributor.transferOwnership(address(0x5555));
    }

    function test_transferOwnership_revert_zeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(AirdropDistributor.ZeroAddress.selector));
        distributor.transferOwnership(address(0));
    }

    function test_acceptOwnership_revert_notPending() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(AirdropDistributor.NotOwner.selector));
        distributor.acceptOwnership();
    }

    /*//////////////////////////////////////////////////////////////
                         VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_claimsOpen_false_noAirdrop() public view {
        assertFalse(distributor.claimsOpen(address(token)));
    }

    function test_claimsOpen_false_poolNotCompleted() public {
        vm.prank(projectOwner);
        distributor.createAirdrop(address(token), address(pool), merkleRoot, TOTAL, "QmTest123");

        assertFalse(distributor.claimsOpen(address(token)));
    }

    function test_claimsOpen_true() public {
        _setupAirdropCompleted();
        assertTrue(distributor.claimsOpen(address(token)));
    }

    function test_hasClaimed_false() public {
        _setupAirdropCompleted();
        assertFalse(distributor.hasClaimed(address(token), user1));
    }

    function test_hasClaimed_true() public {
        _setupAirdropCompleted();

        vm.prank(user1);
        distributor.claim(address(token), AMOUNT_1, proofs[0]);

        assertTrue(distributor.hasClaimed(address(token), user1));
    }

    /*//////////////////////////////////////////////////////////////
                     CLAIMS + WITHDRAWAL COMBO
    //////////////////////////////////////////////////////////////*/

    function test_withdrawRemainingAfterPartialClaims() public {
        _setupAirdropCompleted();

        vm.prank(user1);
        distributor.claim(address(token), AMOUNT_1, proofs[0]);

        uint256 remaining = TOTAL - AMOUNT_1;
        address recipient = address(0x9999);

        vm.prank(projectOwner);
        distributor.requestWithdraw(address(token), recipient, remaining);

        distributor.approveWithdraw(address(token));

        vm.prank(projectOwner);
        distributor.executeWithdraw(address(token));

        assertEq(token.balanceOf(recipient), remaining);
        assertEq(token.balanceOf(address(distributor)), 0);
    }
}
