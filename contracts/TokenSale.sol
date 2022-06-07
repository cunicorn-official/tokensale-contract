// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.13;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./interfaces/ITokenLocker.sol";

/// @title Tokensale contract for sale token to public user
/// @dev Using proxy pattern be careful to use when need to improve contract to next version
contract TokenSale is Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20Upgradeable for IERC20MetadataUpgradeable;

    struct TokenBuy {
        address tokenBuyAddress;
        uint256 rate;
        uint256 min;
        uint256 max;
    }

    struct EtherBuy {
        uint256 rate;
        uint256 min;
        uint256 max;
    }
    
    enum saleMethod{ ETHER, TOKEN, DISTRIBUTOR, ADD_LOCK }
    
    // use from ICO TOKEN Contract
    IERC20MetadataUpgradeable public token;
    // Token Locker 
    ITokenLocker public tokenLocker;

    EtherBuy public etherBuy;          
    
    uint256 public RATE_DECIMALS;
    
    uint256 public FUNDING_GOAL;
    
    uint256 public tokenRaised;
    
    uint256 public etherRaised;
    
    uint256 public totalTokenLock;
    // user limit tokensale token receive
    uint256 public limitTokenReceivePerUser;    
    
    uint48 public whitelistEndTime;

    uint48 public tokenSaleStartTime;

    uint48 public tokenSaleEndTime;    

    bool public isPauseSaleWithEther;

    bool public isPauseSaleWithToken;    

    bool public isPauseSaleWithDistributor;                
    // for check limit token per user can receive
    bool public isCheckLimitPerUser;

    // token buy address list
    address[] public tokenBuyAddresses;
    // keep track balance token buy raisd in separate method
    mapping(address => uint256) public tokenBuyRaised;
    // keep token buy data
    mapping(address => TokenBuy) public tokenBuys;
    // keep user tokensale token receive balance 
    mapping(address => uint256) public userTokenReceiveBalance;    
    // user native buy balance
    mapping(address => uint256) public userNativeBuyBalance;
    // user seperate token buy balance
    mapping(address => mapping(address => uint256)) public userTokenBuyBalance;
    
    mapping(address => bool) public whitelistUsers;
    // set token exchange rate for token
    mapping(address => uint256) public tokenRateTokenBuys;    
    // keep token receive per method
    mapping(saleMethod => uint256) public totalTokenReceivePerMethod;    

    // setup role
    bytes32 public constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant FUND_OWNER_ROLE = keccak256("FUND_OWNER_ROLE");
    bytes32 public constant CONFIG_ROLE = keccak256("CONFIG_ROLE");
    bytes32 public constant WHITELIST_ROLE = keccak256("WHITELIST_ROLE");

    // event
    event BuyToken(address indexed buyer, uint256 ethPaid, uint256 tokenReceived, uint256 timestamp);    
    event BuyTokenWithToken(address indexed buyer, uint256 tokenPaid, uint256 tokenReceived, address tokenBuyAddress, uint256 timestamp);
    event BuyTokenWithDistributor(address indexed receiver, uint256 tokenReceived, string indexed referenceTx); 
    event ExtractEther(address indexed receiver, uint256 ethReceived);    
    event ExtractToken(address indexed receiver, uint256 tokenBuyReceived);    
    event ClaimLockToken(address indexed receiver, uint256 claimableToken, uint256 chunkClaimed);
    event AddClaimLockToken(address indexed receiver, uint256 lockTokenAmount);
    event AddWhitelistUser(address[] whitelistUsersAddress);
    event SetSalePeriod(uint48 tokenSaleStartTime, uint48 tokenSaleEndTime);
    event SetWhitelistPeriod(uint48 whitelistEndTime);
    event SetLimitTokenReceivePerUser(bool isCheckLimitPerUser, uint256 limitTokenReceivePerUser);
    event SetPauseSale(bytes32 saleChannel, bool isPauseSale);

    // modifier
    modifier whenTokenSaleCompleted {
        require(block.timestamp > tokenSaleEndTime || tokenRaised >= FUNDING_GOAL, "TOKENSALE: NOT_COMPLETE_YET");
        _;
    }

    modifier whenSaleWithEtherNotPause {
        require(!isPauseSaleWithEther, "TOKENSALE: ETHER_PAUSE");
        _;
    }

    modifier whenSaleWithTokenNotPause {
        require(!isPauseSaleWithToken, "TOKENSALE: TOKEN_PAUSE");
        _;
    }

     modifier whenSaleWithDistributorNotPause {
        require(!isPauseSaleWithDistributor, "TOKENSALE: DISTRIBUTOR_PAUSE");
        _;
    }

    /// @dev initial function for contract after deploy
    /// @param _tokenSaleStartTime use for set sale start time
    /// @param _tokenSaleEndTime use for set sale end time
    /// @param _token address of token and will set as token sale instance
    /// @param _tokenLocker address of token locker for lock token
    /// @param _fundingGoal goal of this raise fund in term of token amount
    /// @param _distributor address of EOA use for another channel of sale    
    /// @param _keepRateDecimals decimals for keep in calculate exchange rate
    /// @param _etherBuy set rate for native buy    
    function initialize(
        uint48 _tokenSaleStartTime,
        uint48 _tokenSaleEndTime,
        IERC20MetadataUpgradeable _token,
        ITokenLocker _tokenLocker,
        uint256 _fundingGoal,        
        address _distributor,         
        uint256 _keepRateDecimals,
        EtherBuy memory _etherBuy,
        TokenBuy[] memory _tokenBuys
    ) external initializer {

        require (
            _tokenSaleStartTime != 0 &&
            
            _tokenSaleEndTime != 0 &&

            _tokenSaleStartTime < _tokenSaleEndTime &&                        
            
            _fundingGoal != 0 &&

            _keepRateDecimals != 0

        , "TOKENSALE: INITIAL_INVALID_VALUE");   

        __AccessControl_init();
        __ReentrancyGuard_init();

        tokenSaleStartTime = _tokenSaleStartTime;
        
        tokenSaleEndTime = _tokenSaleEndTime;
        
        token = _token;

        tokenLocker = _tokenLocker;

        FUNDING_GOAL = _fundingGoal;

        RATE_DECIMALS = 10 ** _keepRateDecimals; 

        // set ether buy data
        etherBuy = _etherBuy;

        // set allow token to buy
        /// double check rate before set for correct exchange rate
        for (uint256 i = 0; i < _tokenBuys.length; i++) {
            TokenBuy memory tokenBuy = _tokenBuys[i];
            // mapping token buy data
            tokenBuys[tokenBuy.tokenBuyAddress] = tokenBuy;
            // keep address in array for use when extract fund
            tokenBuyAddresses.push(tokenBuy.tokenBuyAddress);
        }

        // set up role
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(DISTRIBUTOR_ROLE, _distributor);
        _setupRole(PAUSER_ROLE, msg.sender);
        _setupRole(FUND_OWNER_ROLE, msg.sender);
        _setupRole(CONFIG_ROLE, msg.sender);
        _setupRole(WHITELIST_ROLE, msg.sender);
    }

    /// @notice Add whitelist user to allow buy in whitelist period
    /// @param _whitelistUsersAddress array of allow address for use in whitelist period
    function addWhitelistUser(address[] calldata _whitelistUsersAddress) external onlyRole(WHITELIST_ROLE) {
        for (uint256 i = 0; i < _whitelistUsersAddress.length; i++) {
            whitelistUsers[_whitelistUsersAddress[i]] = true;
        }
        emit AddWhitelistUser(_whitelistUsersAddress);
    }
    
    /// @notice Set period of this sale
    /// @dev Use this for extend or change sale period
    /// @param _tokenSaleStartTime start time of this sale
    /// @param _tokenSaleEndTime end time of this sale
    function setSalePeriod(uint48 _tokenSaleStartTime, uint48 _tokenSaleEndTime) external onlyRole(CONFIG_ROLE) {
        require(_tokenSaleStartTime != 0, "TOKENSALE: INPUT_ZERO_AMOUNT");
        require(_tokenSaleEndTime != 0, "TOKENSALE: INPUT_ZERO_AMOUNT");
        require(_tokenSaleStartTime < _tokenSaleEndTime, "TOKENSALE: CONFIG_INVALID_SALE_TIME");
        // set sale period
        tokenSaleStartTime = _tokenSaleStartTime;
        tokenSaleEndTime = _tokenSaleEndTime;
        emit SetSalePeriod(_tokenSaleStartTime, _tokenSaleEndTime);
    }

    /// @notice Set period of whitelist
    /// @dev Start whitelist time will equal tokenSaleStartTime
    /// If not have whitelist period just set _whitelistEndTime equal tokenSaleStartTime
    /// @param _whitelistEndTime end time of this whitelist period
    function setWhitelistPeriod(uint48 _whitelistEndTime) external onlyRole(CONFIG_ROLE) {
        require(_whitelistEndTime >= tokenSaleStartTime && _whitelistEndTime <= tokenSaleEndTime, "TOKENSALE: CONFIG_INVALID_WHITELIST_ENDTIME");        
        // set whitelist period
        // if set whitelistEndTime == tokenSaleStartTime mean no whitelist
        whitelistEndTime = _whitelistEndTime;
        emit SetWhitelistPeriod(whitelistEndTime);
    }
    
    /// @notice Set token limit per user
    /// @dev If not have token limit just set _isCheckLimitPerUser to false
    /// @param _isCheckLimitPerUser boolean for check this sale have token limit per user
    /// @param _limitTokenReceivePerUser amount of limit token can receive per user
    function setLimitTokenReceivePerUser(bool _isCheckLimitPerUser, uint256 _limitTokenReceivePerUser) external onlyRole(CONFIG_ROLE) {
        require(_limitTokenReceivePerUser != 0, "TOKENSALE: INPUT_ZERO_AMOUNT");
        limitTokenReceivePerUser = _limitTokenReceivePerUser;
        isCheckLimitPerUser = _isCheckLimitPerUser;
        emit SetLimitTokenReceivePerUser(_isCheckLimitPerUser, _limitTokenReceivePerUser);
    }

    /// @notice Pause sale for channel ether, token and distributor
    /// @dev Set to ALL will pause all channel
    /// @param _saleChannel string channel for sale type
    /// @param _isPauseSale boolean for indicate this sale will pause or not
    function setPauseSale(bytes32 _saleChannel, bool _isPauseSale) external onlyRole(PAUSER_ROLE) {
        if (_saleChannel == keccak256("ETHER")) {
            isPauseSaleWithEther = _isPauseSale;
        } else if (_saleChannel == keccak256("TOKEN")) {
            isPauseSaleWithToken = _isPauseSale;
        } else if (_saleChannel == keccak256("DISTRIBUTOR")) {
            isPauseSaleWithDistributor = _isPauseSale;
        } else if (_saleChannel == keccak256("ALL")) {
            isPauseSaleWithEther = _isPauseSale;
            isPauseSaleWithToken = _isPauseSale;
            isPauseSaleWithDistributor = _isPauseSale;
        }
        emit SetPauseSale(_saleChannel, _isPauseSale);
    }

    /// @notice Check if this time in whitelist period or not
    /// @dev If not have whitelist period will return false at first condition    
    function isWhitelistPeriod() public view returns (bool) {
        return whitelistEndTime != tokenSaleStartTime && block.timestamp >= tokenSaleStartTime && block.timestamp <= whitelistEndTime;
    }

    /// @notice Check if this sale complete
    function isTokenSaleCompleted() external view returns (bool) {
        return block.timestamp > tokenSaleEndTime || tokenRaised >= FUNDING_GOAL;
    }

    /// @notice Sale with native coin, e.g. ETH on ETHEREUM or BNB on BSC
    /// @dev This use for buy token sale with coin, e.g. ETH on ETHEREUM or BNB on BSC and fallback and receive will trigger this buy
    function buy() external payable nonReentrant whenSaleWithEtherNotPause {
        
        require(block.timestamp >= tokenSaleStartTime && block.timestamp <= tokenSaleEndTime, "TOKENSALE: END_TIME");                   
        
        require(tokenRaised < FUNDING_GOAL, "TOKENSALE: CAP_REACH");

        // check and allow whitelist user to buy first
        // after whitelist period will allow any user to buy
        if (isWhitelistPeriod()) {
            require(whitelistUsers[msg.sender], "TOKENSALE: ALLOW_ONLY_WHITELIST_ADDRESS");    
        }        

        
        require(msg.value >= etherBuy.min, "TOKENSALE: AMOUNT_LEES_THAN_MIN");
        require(msg.value <= etherBuy.max, "TOKENSALE: AMOUNT_MORE_THAN_MAX");

        uint256 tokensToReceived;
        
        uint256 etherUsed = msg.value;
        
        address payable sender = payable(msg.sender);
        
        uint256 etherExceed;
        
        uint256 etherUnit = 1 ether;

        uint256 tokenReceivedUnit = 10 ** token.decimals();        

        // calculate receive token and have convert unit receive token
        // which support token with decimals is not 18
        tokensToReceived = etherUsed * tokenReceivedUnit / etherUnit * etherBuy.rate / RATE_DECIMALS;
        
        // Check if we have reached and exceeded the funding goal to refund the exceeding tokens and ether
        if (tokenRaised + tokensToReceived > FUNDING_GOAL) {
            
            uint256 tokensToReceivedExceed = tokenRaised + tokensToReceived - FUNDING_GOAL;
            // formular
            // convert exceed token back to ether exceed
            etherExceed = tokensToReceivedExceed * etherUnit / tokenReceivedUnit * RATE_DECIMALS / etherBuy.rate;
            // reduce etherExceed exceed from etherUsed receive
            etherUsed -= etherExceed;
            // reduce token exceed from total receive
            tokensToReceived -= tokensToReceivedExceed;
            // send exceed ether back to user
            sender.transfer(etherExceed);
        }

        // check limit per user
        if (isCheckLimitPerUser) {
            require(userTokenReceiveBalance[sender] + tokensToReceived <= limitTokenReceivePerUser, "TOKENSALE: EXCEED_LIMIT");
        }
            
        tokenRaised += tokensToReceived;
                
        etherRaised += etherUsed;

        // count each user for native buy balance
        userNativeBuyBalance[sender] += etherUsed;

        // count each user tokensale token receive balance
        userTokenReceiveBalance[sender] += tokensToReceived;

        // count total token receive per method
        totalTokenReceivePerMethod[saleMethod.ETHER] += tokensToReceived;

        // lock token user
        tokenLocker.lock(sender, tokensToReceived);

        emit BuyToken(sender, etherUsed, tokensToReceived, block.timestamp);
    }
    
    /// @notice Sale with token, e.g. USDT, BUSD and wBTC
    /// @dev This use for buy token sale with token, e.g. USDT, BUSD and wBTC
    /// can support decimals token with is not default like 6 in USDC 
    /// and exchage rate for each token max is 18 decimal    
    /// @param _amount amount for token that want to buy in this token sale
    /// @param _tokenBuyAddress address of token and allow only whitelist token address
    function buyWithToken(uint256 _amount, address _tokenBuyAddress) external nonReentrant whenSaleWithTokenNotPause {
        
        require(block.timestamp >= tokenSaleStartTime && block.timestamp <= tokenSaleEndTime, "TOKENSALE: END_TIME");   
        
        require(tokenRaised < FUNDING_GOAL, "TOKENSALE: CAP_REACH");
        
        TokenBuy memory tokenBuyData = tokenBuys[_tokenBuyAddress];
        // check whitelist token buy
        require(tokenBuyData.tokenBuyAddress != address(0), "TOKENSALE: ALLOW_ONLY_WHITELIST_TOKEN");

        // check and allow whitelist user to buy first
        // after whitelist period will allow any user to buy
        if (isWhitelistPeriod()) {
            require(whitelistUsers[msg.sender], "TOKENSALE: ALLOW_ONLY_WHITELIST_ADDRESS");    
        }

        // check min max
        require(_amount >= tokenBuyData.min, "TOKENSALE: AMOUNT_LEES_THAN_MIN");
        require(_amount <= tokenBuyData.max, "TOKENSALE: AMOUNT_MORE_THAN_MAX");
    
        // set token buy instance
        IERC20MetadataUpgradeable tokenBuy = IERC20MetadataUpgradeable(_tokenBuyAddress);
        
        uint256 tokensToReceived;
        
        uint256 tokenBuyUsed = _amount;
        
        address sender = msg.sender;
        
        uint256 tokenBuyExceed;
        
        uint256 tokenBuyUnit = 10 ** tokenBuy.decimals();
        
        uint256 tokenReceivedUnit = 10 ** token.decimals();        

        uint256 tokenRateTokenBuy = tokenBuyData.rate;
 
        // trasfer token buy to tokensale
        tokenBuy.safeTransferFrom(sender, address(this), tokenBuyUsed);
        
        // calculate receive token and have convert unit receive token
        // which support sale token with decimals is not 18
        // and decimals for token buy is not 18

        tokensToReceived = tokenBuyUsed * tokenReceivedUnit / tokenBuyUnit * tokenRateTokenBuy / RATE_DECIMALS;
        
        // Check if we have reached and exceeded the funding goal to refund the exceeding tokens and ether
        if (tokenRaised + tokensToReceived > FUNDING_GOAL) {
            
            uint256 tokensToReceivedExceed = tokenRaised + tokensToReceived - FUNDING_GOAL;
            
            // formular
            // convert exceed token back to token buy exceed;
            tokenBuyExceed = tokensToReceivedExceed * tokenBuyUnit / tokenReceivedUnit * RATE_DECIMALS / tokenRateTokenBuy;
                                        
            tokenBuyUsed -= tokenBuyExceed;
            
            tokensToReceived -= tokensToReceivedExceed;
            // transfer exceed token buy to user
            tokenBuy.safeTransfer(sender, tokenBuyExceed);
        }

        // check limit per user
        if (isCheckLimitPerUser) {
            require(userTokenReceiveBalance[sender] + tokensToReceived <= limitTokenReceivePerUser, "TOKENSALE: EXCEED_LIMIT");
        }    

        tokenRaised += tokensToReceived;
            
        // count raised token buy raised
        tokenBuyRaised[_tokenBuyAddress] += tokenBuyUsed;

        // count each user for token buy balance
        userTokenBuyBalance[sender][_tokenBuyAddress] += tokenBuyUsed;

        // count each user tokensale token receive balance
        userTokenReceiveBalance[sender] += tokensToReceived;

        // count total token receive per method
        totalTokenReceivePerMethod[saleMethod.TOKEN] += tokensToReceived;                
        
        // lock token user
        tokenLocker.lock(sender, tokensToReceived);
        
        emit BuyTokenWithToken(sender, tokenBuyUsed, tokensToReceived, _tokenBuyAddress, block.timestamp);
    }

    /// @notice Sale with distributor, e.g. CCP
    /// @dev Must send reference for keep track and reconcile each transaction
    /// @param _receiver address of user who will receive token
    /// @param _amount amount of token of this sale that user will receive
    /// @param _reference reference string for keep track and reconcile each transaction
    function buyTokenWithDistributor(address _receiver, uint256 _amount, string memory _reference) external nonReentrant onlyRole(DISTRIBUTOR_ROLE) whenSaleWithDistributorNotPause {            
        
        require(_receiver != address(0), "TOKENSALE: INPUT_ZERO_ADDRESS");
        
        require(_amount != 0, "TOKENSALE: INPUT_ZERO_AMOUNT");

        require(tokenRaised < FUNDING_GOAL, "TOKENSALE: CAP_REACH");

        require(tokenRaised + _amount <= FUNDING_GOAL, "TOKENSALE: INSUFFICIENT_TOKEN");   
        
        require(block.timestamp >= tokenSaleStartTime && block.timestamp <= tokenSaleEndTime, "TOKENSALE: END_TIME");

        // check and allow whitelist user to buy first
        // after whitelist period will allow any user to buy
        if (isWhitelistPeriod()) {
            require(whitelistUsers[_receiver], "TOKENSALE: ALLOW_ONLY_WHITELIST_ADDRESS");    
        }
        
        // check limit per user
        if (isCheckLimitPerUser) {
            require(userTokenReceiveBalance[_receiver] + _amount <= limitTokenReceivePerUser, "TOKENSALE: EXCEED_LIMIT");
        }

        uint256 tokensToReceived = _amount;                                                                
                
        tokenRaised += tokensToReceived;

        // count total token receive per method
        totalTokenReceivePerMethod[saleMethod.DISTRIBUTOR] += tokensToReceived;

        // count each user tokensale token receive balance
        userTokenReceiveBalance[_receiver] += tokensToReceived;

        // lock token user
        tokenLocker.lock(_receiver, tokensToReceived);
        
        // emit actual token receive and lock token
        emit BuyTokenWithDistributor(_receiver, tokensToReceived, _reference);
    }
    
    /// @notice Extract fund only ether
    /// @dev Only FUND_OWNER_ROLE can extract this fund
    function extractEther() external nonReentrant onlyRole(FUND_OWNER_ROLE) whenTokenSaleCompleted {
        address payable fundOwner = payable(msg.sender);
        uint256 amount = address(this).balance;        
        // send ether to fund owner with amount more than zero
        if (amount != 0) {
            fundOwner.transfer(amount);
            emit ExtractEther(msg.sender, amount);
        }
    }
    
    /// @notice Extract fund only token, e.g. USDT, BUSD, wBTC
    /// @dev Only FUND_OWNER_ROLE can extract this fund
    function extractTokenBuy() external nonReentrant onlyRole(FUND_OWNER_ROLE) whenTokenSaleCompleted {
        for (uint256 i = 0; i < tokenBuyAddresses.length; i++) {
            // set token buy
            IERC20MetadataUpgradeable tokenBuy = IERC20MetadataUpgradeable(tokenBuyAddresses[i]);
            uint256 amount = tokenBuy.balanceOf(address(this));
            // send token buy to fund owner with amount more than zero
            if (amount != 0) {
                tokenBuy.safeTransfer(msg.sender, amount);
                emit ExtractToken(msg.sender, amount);
            }           
        }        
    }
}