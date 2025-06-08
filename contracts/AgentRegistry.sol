// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IAgentRegistry
 * @dev Interface for the AgentRegistry contract, defining its external API.
 * This allows other contracts and off-chain applications to interact with AgentRegistry
 * without needing its full implementation, ensuring better modularity and upgradeability.
 * Includes definitions for Phase 2 features.
 */
interface IAgentRegistry {
    // --- Structs 
    struct Agent {
        string name;
        address payable owner;
        string endpointUrl;
        uint256 price;
        bool registered;
        uint256 nftTokenId; 
    }

    // --- Events 
    event AgentRegistered(
        uint256 indexed agentId,
        string name,
        address indexed owner,
        uint256 price,
        uint256 nftTokenId // <--- ADDED THIS LINE
    );

    event AgentUpdated(
        uint256 indexed agentId,
        string newEndpointUrl,
        uint256 newPrice
    );

    event AgentDeregistered(uint256 indexed agentId);

    // --- Functions 
    function registerAgent(
        string memory _name,
        string memory _endpointUrl,
        uint256 _price
    ) external returns (uint256);

    function updateAgent(
        uint256 _agentId,
        string memory _newEndpointUrl,
        uint256 _newPrice
    ) external;

    function deregisterAgent(uint256 _agentId) external;

    function reactivateAgent(uint256 _agentId) external;

    
    function agents(uint256) external view returns (
        string memory name,
        address payable owner,
        string memory endpointUrl,
        uint256 price,
        bool registered,
        uint256 nftTokenId 
    );

    function nextAgentId() external view returns (uint256);

    // Inherited from Ownable, required for proper interface definition
    function owner() external view returns (address);
    function renounceOwnership() external;
    function transferOwnership(address newOwner) external;
}