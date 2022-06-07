// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ITokenLocker {
    struct UserInfo {
        uint256 totalReceiveToken;
        uint256 totalClaimedToken;
        uint256 initialChunkToken;
        uint256 lastClaimChunk;
    }

    event Lock(address indexed receiver, uint256 amount);
    event Deposit(uint256 amount, uint256 totalToken);
    event Withdraw(uint256 amount, uint256 totalToken, address to);
    event Claim(address indexed receiver, uint256 totenToClaim);
    event ExtractToken(address indexed token, uint256 amount, address to);

    function lock(address _receiver, uint256 _totalReceive) external;

    function pendingToken(address _receiver)
        external
        view
        returns (uint256 pending);

    function usersLength() external view returns (uint256);

    function claim(address _receiver) external;

    function claimMultiple(address[] calldata _receivers) external;

    function deposit(uint256 amount) external;

    function withdraw(uint256 amount, address to) external;

    function extractToken(
        IERC20 _token,
        uint256 amount,
        address to
    ) external;
}