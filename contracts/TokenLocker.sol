// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/ITokenLocker.sol";

/// @title PrivateSaleClaimer for private sale claim token in vesting model
/// @author natthapach@cunicorn
/// @notice this contract use for private sale token, please check which token that this contract selling
/// @dev this contract use proxy upgradeable, multi role access control and 10**6 based denominator
/// this contract already optimize gas used by storage layout, be safe for add or change order of state variable
/// Enjoy reading. Hopefully it's bug-free. I bless, You bless, God bless. Thank you.
contract TokenLocker is
    ITokenLocker,
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable
{
    /// === PERCENTAGE VARIABLE ===
    /// @notice initial release percent when buy token, safe use with DENOMINATOR
    uint48 public INITIAL_RELEASE_PERCENT;
    /// @notice release percent for each chunk, safe use with DENOMINATOR
    uint48 public CHUNK_RELEASE_PERCENT;
    /// NOTE for example 100% is 1 * DENOMINATOR, so 5% is 5/100 * DENOMINATOR

    /// @notice denominator for shift decimal in math divide
    uint48 public DENOMINATOR;

    /// === TIME VARIABLE ===
    /// @notice timestamp for release of first chunk
    uint48 public FIRST_RELEASE_TIMESTAMP;
    /// @notice timestamp for release of second chunk
    uint48 public SECOND_RELEASE_TIMESTAMP;
    /// @notice duration of each chunk
    uint48 public CHUNK_TIMEFRAME;
    /// @notice max chunk of this vesting plan, will calculate in initialize method
    uint16 public MAX_CHUNK;

    /// === TOKEN ===
    /// @notice private sale token for this contract
    IERC20 public token;

    /// === TOTAL COLLECTOR VARIABLE ===
    /// @notice total token for sale, can change only by deposit/withdraw method
    uint256 public totalToken;
    /// @notice total token already sale, include unclaimed token
    uint256 public totalLock;
    /// @notice total token already claim, include initial token
    /// @dev when all use claim all token, totalSale will equal to totalClaim
    uint256 public totalClaimed;

    /// === ROLE HASH VARIABLE ===
    bytes32 public constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");
    bytes32 public constant FUND_OWNER_ROLE = keccak256("FUND_OWNER_ROLE");

    /// === USER INFO VARIABLE ===
    /// @notice mapping for user address to user information
    mapping(address => UserInfo) public userInfo;
    /// @notice array of unique buyer address
    address[] public users;

    /// @notice modifier for checking only call contract after fist release
    modifier afterFirstRelease() {
        require(
            block.timestamp >= FIRST_RELEASE_TIMESTAMP,
            "LOCKER: OUT_OF_DATE"
        );
        _;
    }

    /// @notice Initialize contract after deploy
    /// @param _initialReleasePercent release percent on first release
    /// @param _chunkReleasePercent release percent of each chunk
    /// @param _firstReleaseTimestamp timestamp of first chuck to be claim
    /// @param _secondReleaseTimestamp timestamp of second chuck to be claim, for give ability to skip gap time between 1st and 2nd release
    /// @param _chunkTimeframe time range of each chuck in 2nd - n-th release
    /// @param _token address of ICO token
    function initialize(
        uint48 _initialReleasePercent,
        uint48 _chunkReleasePercent,
        uint48 _firstReleaseTimestamp,
        uint48 _secondReleaseTimestamp,
        uint48 _chunkTimeframe,
        IERC20 _token
    ) public initializer {
        require(
            address(_token) != address(0) &&
                _firstReleaseTimestamp <= _secondReleaseTimestamp,
            "LOCKER: INVALID_PARAMETER"
        );
        // initial parent
        __AccessControl_init();
        __ReentrancyGuard_init();

        // setup state variable
        INITIAL_RELEASE_PERCENT = _initialReleasePercent;
        CHUNK_RELEASE_PERCENT = _chunkReleasePercent;
        FIRST_RELEASE_TIMESTAMP = _firstReleaseTimestamp;
        SECOND_RELEASE_TIMESTAMP = _secondReleaseTimestamp;
        CHUNK_TIMEFRAME = _chunkTimeframe;
        token = _token;
        DENOMINATOR = 10**6;

        // calculate max chunk
        // @formula max_chunk = ceil[(100% - init%) / chunk%] + 1
        MAX_CHUNK = uint16(
            Math.ceilDiv(
                ((1 * DENOMINATOR) - _initialReleasePercent),
                _chunkReleasePercent
            ) + 1 // +1 for initial chunk
        );

        // setup access role
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(FUND_OWNER_ROLE, msg.sender);
    }

    /// @dev call transferFram token and check it success
    /// @param _token token to be called
    /// @param sender sender
    /// @param receiver receiver
    /// @param amount amount
    function _safeTransferFrom(
        IERC20 _token,
        address sender,
        address receiver,
        uint256 amount
    ) internal {
        require(
            _token.transferFrom(sender, receiver, amount),
            "LOCKER: TRANSFER_FAIL"
        );
    }

    /// @dev call transfer token and check it success
    /// @param _token token to be called
    /// @param receiver receiver
    /// @param amount amount
    function _safeTransfer(
        IERC20 _token,
        address receiver,
        uint256 amount
    ) internal {
        require(_token.transfer(receiver, amount), "LOCKER: TRANSFER_FAIL");
    }

    /// @notice buy private sale token by distributor
    /// @param _receiver token receiver of this purchasing
    /// @param _totalReceive amount of token in this purchasing
    function lock(address _receiver, uint256 _totalReceive)
        external
        override
        nonReentrant
        onlyRole(DISTRIBUTOR_ROLE)
    {
        // 1. CHECK
        uint256 _totalLock = totalLock; // for gas reduce
        require(_totalReceive > 0, "LOCKER: INVALID_AMOUNT");
        require(
            _totalLock + _totalReceive <= totalToken,
            "LOCKER: INSUFFICIENT_TOKEN"
        );

        // 2. EFFECT
        //  2.1 calculate inital release token
        //  initToken = token_receive * initPercent
        uint256 initToken = (_totalReceive * INITIAL_RELEASE_PERCENT) /
            DENOMINATOR;
        //  2.2 update userInfo
        //   2.2.1 query userInfo, if new all value is zero
        UserInfo storage _userInfo = userInfo[_receiver]; // try to use memory cannot reduce gas in this case

        //   2.2.2 if new user, add to list
        if (_userInfo.totalReceiveToken == 0) {
            users.push(_receiver);
        }

        //   2.2.3 calculate pending token if user already claim token
        uint256 pending = 0;
        if (_userInfo.lastClaimChunk != 0) {
            // if user already claim in the previous `totalReceive`, user will get claim token with same previous chuck on new totalReceive
            // @formula
            // pending = min[ initToken + (lastClaimChunk - 1) * chuckPercent * totalReceive, totalReceive ]
            pending = Math.min(
                (initToken +
                    ((_userInfo.lastClaimChunk - 1) *
                        CHUNK_RELEASE_PERCENT *
                        _totalReceive) /
                    DENOMINATOR),
                _totalReceive
            );
        }
        //   2.2.4 udpdate info
        _userInfo.totalReceiveToken += _totalReceive;
        _userInfo.initialChunkToken += initToken;
        _userInfo.totalClaimedToken += pending;

        //  2.3 update total variables
        totalLock = _totalLock + _totalReceive;

        // 3. INTERACT
        //  3.1 tranfer initial token
        if (pending != 0) {
            // group a little effect and interact in same condition for easy read and reduce gas
            uint256 _totalClaimed = totalClaimed;
            totalClaimed = _totalClaimed + pending;

            _safeTransfer(token, _receiver, pending);
        }

        // 4. EMIT
        emit Lock(_receiver, _totalReceive);
    }

    /// @notice calculate pending token to claim for given receiver address
    /// @param _receiver receiver address
    /// @return pending token to claim in Wei
    function pendingToken(address _receiver)
        external
        view
        override
        returns (uint256 pending)
    {
        uint256 _firstReleaseTimestamp = FIRST_RELEASE_TIMESTAMP;
        uint256 _secondReleaseTimestamp = SECOND_RELEASE_TIMESTAMP;
        if (block.timestamp < _firstReleaseTimestamp) {
            return 0;
        }
        UserInfo memory _userInfo = userInfo[_receiver];

        uint256 chunkNo = 0;
        if (block.timestamp >= _firstReleaseTimestamp) {
            // in case can claim first chunk, set base to 1 and can compute more in next line
            chunkNo = 1;
        }
        if (block.timestamp >= _secondReleaseTimestamp) {
            // chunkNo = min( ceil((ts - SECOND_TS + 1) / TF), MAX_CHUNK)
            // add 1 for shift in case ts == SECOND_TS
            chunkNo += uint256(
                Math.min(
                    Math.ceilDiv(
                        block.timestamp - _secondReleaseTimestamp + 1,
                        CHUNK_TIMEFRAME
                    ),
                    MAX_CHUNK - 1
                )
            );
        }

        // formula = min[ (totalReceive * initialPercent + (chunk - 1) * totalReceive) - totalClaimed, totalReceive - totalClaimed ]
        pending = Math.min(
            (_userInfo.initialChunkToken +
                ((chunkNo - 1) *
                    CHUNK_RELEASE_PERCENT *
                    _userInfo.totalReceiveToken) /
                DENOMINATOR) - _userInfo.totalClaimedToken,
            _userInfo.totalReceiveToken - _userInfo.totalClaimedToken
        );
    }

    /// @notice get number of buyer in private sale
    /// @dev use with buyers for get all buyer address
    /// @return number of buyer in private sale
    function usersLength() external view override returns (uint256) {
        return users.length;
    }

    /// @dev internal function for perform claim
    /// @param _receiver given receiver
    function _claim(address _receiver) internal {
        // 1. CHECK
        UserInfo memory _userInfo = userInfo[_receiver]; // memory local for gas reduce
        //  1.1 check user is in private sale
        require(_userInfo.totalReceiveToken > 0, "LOCKER: NO_TOKEN_TO_CLAIM");

        //  1.2 token to claim
        //   1.2.1 calculate current chunk no.
        uint256 chunkNo = 0;
        if (block.timestamp >= FIRST_RELEASE_TIMESTAMP) {
            chunkNo = 1;
        }
        uint256 _secondReleaseTimestamp = SECOND_RELEASE_TIMESTAMP; // gas reduce
        if (block.timestamp >= _secondReleaseTimestamp) {
            // chunkNo = min( ceil((ts - SECOND_TS + 1) / TF), MAX_CHUNK)
            // add 1 for shift in case ts == SECOND_TS
            chunkNo += uint256(
                Math.min(
                    Math.ceilDiv(
                        block.timestamp - _secondReleaseTimestamp + 1,
                        CHUNK_TIMEFRAME
                    ),
                    MAX_CHUNK - 1
                )
            );
        }
        require(
            _userInfo.lastClaimChunk < chunkNo,
            "LOCKER: NO_TOKEN_TO_CLAIM"
        );

        //   1.2.2 calculate pending token
        //      formula = min[ (totalReceive * initialPercent + (chunk - 1) * totalReceive) - totalClaimed, totalReceive - totalClaimed ]
        uint256 pending = Math.min(
            (_userInfo.initialChunkToken +
                ((chunkNo - 1) *
                    CHUNK_RELEASE_PERCENT *
                    _userInfo.totalReceiveToken) /
                DENOMINATOR) - _userInfo.totalClaimedToken,
            _userInfo.totalReceiveToken - _userInfo.totalClaimedToken
        );

        require(pending > 0, "LOCKER: NO_TOKEN_TO_CLAIM");

        // 2. EFFECT
        //  2.1 update user info
        UserInfo storage __userInfo = userInfo[_receiver];
        __userInfo.totalClaimedToken = _userInfo.totalClaimedToken + pending;
        __userInfo.lastClaimChunk = chunkNo;
        //   2.2 update total variable
        uint256 _totalClaimed = totalClaimed;
        totalClaimed = _totalClaimed + pending;

        // 3. INTERACT
        //  3.1 transfer pending token to receiver
        _safeTransfer(token, _receiver, pending);

        // 4. EMIT
        emit Claim(_receiver, pending);
    }

    /// @notice claim pending token for given receiver address, this method freely to everyone can call
    /// @param _receiver target receiver address
    function claim(address _receiver)
        external
        override
        nonReentrant
        afterFirstRelease
    {
        _claim(_receiver);
    }

    /// @notice claim pending token for multiple given receiver address, this method freely to everyone can call
    /// @param _receivers target receivers address
    function claimMultiple(address[] calldata _receivers)
        external
        override
        nonReentrant
        afterFirstRelease
    {
        require(_receivers.length > 0, "LOCKER: EMPTY_ARRAY");
        for (uint256 index = 0; index < _receivers.length; index++) {
            _claim(_receivers[index]);
        }
    }

    /// @notice use by fund owner to deposit token for privatesale
    /// @dev this function use transferFrom, not balanceOf, because give owner to easy control totalToken for privatesale
    /// @param amount amount of token (in Wei)
    function deposit(uint256 amount)
        external
        override
        nonReentrant
        onlyRole(FUND_OWNER_ROLE)
    {
        require(amount > 0, "LOCKER: INVALID_AMOUNT");
        totalToken += amount;

        _safeTransferFrom(token, msg.sender, address(this), amount);

        emit Deposit(amount, totalToken);
    }

    /// @notice use by fund owner to withdraw ICO token only and decrease totalToken for sale
    /// @param amount amount to withdraw
    /// @param to target address to withdrawal
    function withdraw(uint256 amount, address to)
        external
        override
        nonReentrant
        onlyRole(FUND_OWNER_ROLE)
    {
        require(amount > 0, "LOCKER: INVALID_AMOUNT");
        require(amount <= totalToken - totalLock, "LOCKER: INSUFFICIENT_TOKEN");

        totalToken -= amount;

        _safeTransfer(token, to, amount);

        emit Withdraw(amount, totalToken, to);
    }

    /// @notice use by fund owner for extract token from unexpected transfer
    /// @param _token target token address
    /// @param amount extraction amount
    /// @param to target address to withdrawal
    function extractToken(
        IERC20 _token,
        uint256 amount,
        address to
    ) external override nonReentrant onlyRole(FUND_OWNER_ROLE) {
        require(amount > 0, "LOCKER: INVALID_AMOUNT");
        uint256 balance = _token.balanceOf(address(this));

        if (_token == token) {
            // sale token must reduce with reserve token for prevent extract over reserve token
            balance = balance - (totalToken - totalClaimed);
        }
        require(amount <= balance, "LOCKER: INSUFFICIENT_TOKEN");

        _safeTransfer(_token, to, amount);

        emit ExtractToken(address(_token), amount, to);
    }
}
