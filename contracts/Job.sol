// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20; // Ensure this matches your hardhat.config.cjs Solidity version

import "./interfaces/IAgentRegistry.sol"; // To interact with AgentRegistry (for agent details)
import "./interfaces/IJob.sol";          // Import its own interface (for external API definition)

// --- Chainlink Functions Imports ---
// These are essential for connecting your smart contract to off-chain computation.
// FunctionsClient.sol handles sending requests and receiving callbacks.
// Corrected path based on your 'find' command output:
import "@chainlink/contracts/src/v0.8/functions/dev/v1_0_0/FunctionsClient.sol";
// ConfirmedOwner.sol provides owner-only access control for administrative functions.
// Note the 'shared/access' path for newer Chainlink Contracts versions.
import "@chainlink/contracts/src/v0.8/shared/access/ConfirmedOwner.sol";

/**
 * @title Job
 * @dev Manages the creation, payment escrow, execution, and fulfillment of jobs
 * for AI agents via Chainlink Functions.
 * Inherits from FunctionsClient for Chainlink interactions and ConfirmedOwner for administrative control.
 */
contract Job is IJob, FunctionsClient, ConfirmedOwner {
    // --- State Variables ---

    // Immutable reference to the AgentRegistry contract.
    // `immutable` means its value is set once in the constructor and cannot be changed thereafter.
    IAgentRegistry public immutable agentRegistry;

    // --- Chainlink Functions Specific State Variables ---
    // The address of the Chainlink Functions Router contract on the target blockchain (e.g., Arbitrum Sepolia).
    // This is the primary entry point for sending requests to the Chainlink Decentralized Oracle Network (DON).
    address public s_functionsRouter;
    // The ID of the Chainlink Functions subscription.
    // This subscription must be funded with LINK tokens to cover the costs of Chainlink Functions requests.
    uint64 public s_functionsSubscriptionId;
    // The maximum amount of gas the Chainlink DON will pay for when calling back the `fulfill` function.
    // This limit ensures that the callback transaction doesn't run out of gas.
    uint32 public s_callbackGasLimit = 300000; // Default value, can be adjusted by the owner

    // --- Enums ---
    // Enum to track the lifecycle status of a job.
    // Inherited from IJob.sol, no need to redefine here.

    // --- Structs ---
    // Inherited from IJob.sol, no need to redefine here.

    // Mapping from a Chainlink `requestId` (bytes32) to its corresponding `JobDetails` struct.
    // The `requestId` is used as the primary key because Chainlink callbacks use this ID.
    mapping(bytes32 => JobDetails) public jobs;
    // An auxiliary mapping from our internal `jobId` (uint256) to the Chainlink `requestId` (bytes32).
    // This allows users/frontends to query by their internal job ID.
    mapping(uint256 => bytes32) public jobIdToRequestId;
    // A counter to assign sequential, unique internal IDs to new jobs.
    uint256 public nextJobId; // Starts at 0 by default

    // --- Events ---

    /**
     * @dev Emitted when a new job request is successfully created and the Chainlink Functions request is sent.
     * This event provides critical information for off-chain services to track job initiation.
     * @param jobId The unique internal ID of the created job.
     * @param agentId The ID of the agent selected for this job.
     * @param user The address of the user who initiated the job.
     * @param paymentAmount The amount paid for the job (in native token).
     * @param inputData The input provided to the agent.
     * @param requestId The unique Chainlink Functions request ID generated for this job.
     */
    event JobCreated(
        uint256 indexed jobId,      // Indexed for easy lookup of specific jobs
        uint256 agentId,            // Not indexed (max 3 indexed parameters per event for EVM)
        address indexed user,       // Indexed for user-specific job history
        uint256 paymentAmount,
        string inputData,
        bytes32 indexed requestId   // Indexed for Chainlink request tracking
    );

    /**
     * @dev Emitted when a job is successfully fulfilled by the off-chain agent via Chainlink Functions.
     * @param jobId The internal ID of the fulfilled job.
     * @param outputData The successful output string from the agent.
     * @param requestId The Chainlink Functions request ID.
     */
    event JobFulfilled(
        uint256 indexed jobId,      // Indexed
        string outputData,
        bytes32 indexed requestId   // Indexed
    );

    /**
     * @dev Emitted when a job fails during off-chain agent execution via Chainlink Functions.
     * @param jobId The internal ID of the failed job.
     * @param reason A string describing the reason for failure (e.g., from Chainlink).
     * @param requestId The Chainlink Functions request ID.
     */
    event JobFailed(
        uint256 indexed jobId,      // Indexed
        string reason,
        bytes32 indexed requestId   // Indexed
    );

    /**
     * @dev Emitted when the Chainlink Functions Router address is updated by the contract owner.
     * @param oldRouter The previous router address.
     * @param newRouter The newly set router address.
     */
    event FunctionsRouterUpdated(address indexed oldRouter, address indexed newRouter);

    /**
     * @dev Emitted when the Chainlink Functions Subscription ID is updated by the contract owner.
     * @param oldSubscriptionId The previous subscription ID.
     * @param newSubscriptionId The newly set subscription ID.
     */
    event FunctionsSubscriptionUpdated(uint64 indexed oldSubscriptionId, uint64 indexed newSubscriptionId);

    /**
     * @dev Emitted when the Chainlink Functions Callback Gas Limit is updated by the contract owner.
     * @param oldLimit The previous callback gas limit.
     * @param newLimit The newly set callback gas limit.
     */
    event CallbackGasLimitUpdated(uint32 oldLimit, uint32 newLimit);

    // --- Constructor ---

    /**
     * @dev Constructor for the Job contract.
     * Initializes the immutable `agentRegistry` reference, Chainlink Functions router address,
     * subscription ID, and sets the initial administrative owner of this contract.
     * @param _agentRegistryAddress The address of the deployed AgentRegistry contract.
     * @param _functionsRouter The address of the Chainlink Functions Router contract on the target chain.
     * @param _functionsSubscriptionId The ID of the pre-funded Chainlink Functions subscription.
     * @param initialOwner The address that will be the initial administrative owner of this contract.
     */
    constructor(
        address _agentRegistryAddress,
        address _functionsRouter,
        uint64 _functionsSubscriptionId,
        address initialOwner
    )
        // Call base contract constructors:
        ConfirmedOwner(initialOwner)       // Initializes ConfirmedOwner, setting the contract's admin
        FunctionsClient(_functionsRouter)  // Initializes FunctionsClient with the router address
    {
        // Basic validation for constructor arguments
        require(_agentRegistryAddress != address(0), "AgentRegistry address cannot be zero");
        require(_functionsRouter != address(0), "FunctionsRouter address cannot be zero");
        require(_functionsSubscriptionId > 0, "FunctionsSubscriptionId must be greater than zero");

        // Assign initial state variables
        agentRegistry = IAgentRegistry(_agentRegistryAddress);
        s_functionsRouter = _functionsRouter;
        s_functionsSubscriptionId = _functionsSubscriptionId;
    }

    // --- Workaround Modifier for Compilation ---
    // If _onlyFunctionsRouter is not correctly inherited from FunctionsClient.sol
    // due to unusual linking issues, define it directly here as a fallback.
    // This assumes _router is a state variable within FunctionsClient that holds the trusted router address.
    modifier _onlyFunctionsRouter() {
        require(msg.sender == s_functionsRouter, "Only Functions Router can call this");
        _;
    }


    // --- Core Functions ---

    /**
     * @dev Allows a user to create a job for a registered AI agent.
     * The required payment for the agent's service is sent with the transaction (as native token/ETH)
     * and is held in escrow by this contract.
     * A Chainlink Functions request is then initiated to trigger the off-chain AI agent's execution.
     * @param _agentId The unique ID of the agent (from AgentRegistry) that should perform this job.
     * @param _inputData The input data string provided by the user for the agent to process.
     * @param _functionsSourceCode The JavaScript source code that Chainlink Functions will execute off-chain.
     * This code typically makes an HTTP request to the agent's endpoint.
     * @param _functionsSecrets The encrypted secrets (e.g., API keys for external services) needed by the
     * Functions source code. Obtained from Chainlink's Secrets Management.
     * @param _functionsArgs Additional string arguments to pass to the Chainlink Functions source code.
     * These arguments will typically include the agent's `endpointUrl` and the job's `inputData`.
     * @return The unique internal ID assigned to the newly created job.
     */
    function createJob(
        uint256 _agentId,
        string memory _inputData,
        string calldata _functionsSourceCode,
        bytes calldata _functionsSecrets,
        string[] calldata _functionsArgs
    ) public payable returns (uint256) {
        // Retrieve agent details from the AgentRegistry contract.
        IAgentRegistry.Agent memory agent = agentRegistry.agents(_agentId);

        // Basic validation checks for the job creation
        require(agent.registered, "Agent is not registered or active"); // Ensure the target agent exists and is active
        require(msg.value == agent.price, "Incorrect payment amount for this agent"); // Ensure correct payment is sent
        require(bytes(_inputData).length > 0, "Input data cannot be empty"); // Ensure input data is provided
        require(bytes(_functionsSourceCode).length > 0, "Functions source code cannot be empty"); // Ensure Functions code is provided

        // Assign a new unique internal job ID.
        uint256 internalJobId = nextJobId++;

        // --- Prepare arguments for Chainlink Functions ---
        // Combine the agent's endpoint URL and the job's input data with any additional user-provided arguments.
        // This array will be passed to the Chainlink Functions JavaScript source code.
        string[] memory functionsArgsWithEndpoint = new string[](_functionsArgs.length + 2);
        functionsArgsWithEndpoint[0] = agent.endpointUrl; // First arg: Agent's API endpoint
        functionsArgsWithEndpoint[1] = _inputData;      // Second arg: User's input data
        for (uint256 i = 0; i < _functionsArgs.length; i++) {
            functionsArgsWithEndpoint[i + 2] = _functionsArgs[i]; // Append remaining args
        }

        // --- Send the Chainlink Functions request ---
        // This is the core call to trigger the off-chain computation.
        // It returns a unique requestId that identifies this specific request.
        bytes32 requestId = _sendRequest(
            _functionsSourceCode,            // JavaScript source code for the DON
            _functionsSecrets,               // Encrypted secrets (if any, e.g., API keys)
            functionsArgsWithEndpoint,       // Arguments for the JavaScript code
            s_functionsSubscriptionId,       // ID of the pre-funded Chainlink Functions subscription
            s_callbackGasLimit               // Maximum gas for the callback function
        );

        // --- Store Job Details ---
        // Store the job details, primarily using the Chainlink `requestId` as the key.
        jobs[requestId] = JobDetails({
            agentId: _agentId,
            user: msg.sender,
            paymentAmount: msg.value,
            inputData: _inputData,
            outputData: "",              // Will be filled upon fulfillment
            status: JobStatus.Pending,   // Initial status: awaiting Chainlink response
            requestId: requestId,        // Store the Chainlink requestId
            rawResponse: "",             // Will store raw response bytes
            rawError: ""                 // Will store raw error bytes
        });
        // Map our internal `jobId` to the Chainlink `requestId` for easier lookup from frontend/users.
        jobIdToRequestId[internalJobId] = requestId;

        // Emit an event to signal off-chain applications that a new job has been initiated.
        emit JobCreated(internalJobId, _agentId, msg.sender, msg.value, _inputData, requestId);

        return internalJobId; // Return our internal job ID to the caller
    }

    /**
     * @dev Chainlink Functions callback function for successful or failed requests.
     * This function is automatically called by the Chainlink Functions DON after an off-chain execution.
     * It handles both successful responses (`_err` is empty) and errors (`_err` contains data).
     * Access is strictly restricted to the Chainlink Functions Router via the `_onlyFunctionsRouter` modifier.
     * This function must be `internal override` as it implements `FunctionsClient.sol`'s `fulfill`.
     * @param _requestId The unique ID of the Chainlink Functions request that was fulfilled.
     * @param _response The raw bytes response from the Chainlink Functions execution.
     * @param _err The raw bytes error from the Chainlink Functions execution (empty if successful).
     */
    function fulfill(bytes32 _requestId, bytes memory _response, bytes memory _err)
        internal
        override          // Marks this function as overriding a base contract function
        _onlyFunctionsRouter // Ensures only the Chainlink Functions Router can call this
    {
        // Retrieve the job details using the Chainlink `requestId`.
        JobDetails storage job = jobs[_requestId];

        // Ensure the job exists and is in a pending state before processing the callback.
        require(job.status == JobStatus.Pending, "Job is not pending or already fulfilled/failed");

        // Store the raw response and error bytes for debugging/auditability.
        job.rawResponse = _response;
        job.rawError = _err;

        // --- Handle Errors ---
        // If Chainlink Functions reported an fatal error (`_err` is not empty).
        // This typically means the JavaScript source code itself failed or timed out.
        if (_err.length > 0) {
            job.status = JobStatus.Failed; // Mark job as failed.
            // Refund the user. This is an MVP decision; complex protocols might have different dispute resolution.
            (bool refundSuccess, ) = job.user.call{value: job.paymentAmount}(""); // Renamed variable to avoid shadowing
            require(refundSuccess, "Refund transfer failed to user on Chainlink error");
            // Emit JobFailed event, converting bytes error to string for logging.
            emit JobFailed(getInternalJobId(_requestId), string(_err), _requestId);
            return; // Exit function after handling error
        }

        // --- Handle Success ---
        // Attempt to decode the response. We expect the agent's output to be a string.
        string memory outputData;
        try abi.decode(_response, (string)) returns (string memory decodedString) {
            outputData = decodedString; // Successfully decoded the string output
        } catch {
            // Handle cases where the response could not be decoded as a string (e.g., agent returned non-string, or malformed data).
            job.status = JobStatus.Failed; // Mark job as failed due to decoding issue.
            // Refund the user for failed decoding.
            (bool refundSuccess, ) = job.user.call{value: job.paymentAmount}(""); // Renamed variable to avoid shadowing
            require(refundSuccess, "Refund transfer failed to user on decoding error");
            emit JobFailed(getInternalJobId(_requestId), "Agent output decoding failed", _requestId);
            return; // Exit function
        }

        // If decoding was successful, update job details.
        job.outputData = outputData;        // Store the successfully decoded output.
        job.status = JobStatus.Fulfilled;   // Update job status to fulfilled.

        // Release payment to the agent owner.
        IAgentRegistry.Agent memory agent = agentRegistry.agents(job.agentId);
        // Sanity check to ensure the agent owner address is valid.
        require(agent.owner != address(0), "Agent owner address invalid");

        // Transfer the escrowed payment from this contract to the agent's owner.
        (bool paymentSuccess, ) = agent.owner.call{value: job.paymentAmount}(""); // Renamed variable to avoid shadowing
        require(paymentSuccess, "Payment transfer to agent owner failed");

        // Emit an event to notify off-chain systems about the successful job fulfillment.
        emit JobFulfilled(getInternalJobId(_requestId), outputData, _requestId);
    }

    /**
     * @dev Internal helper function to retrieve the internal `jobId` from a Chainlink `requestId`.
     * This is a simple linear search for the MVP. For a large number of jobs, a more efficient
     * lookup (e.g., a reverse mapping `requestIdToJobId`) or off-chain indexing (The Graph)
     * would be necessary.
     * @param _requestId The Chainlink Functions request ID.
     * @return The corresponding internal `jobId`.
     */
    function getInternalJobId(bytes32 _requestId) private view returns (uint256) {
        // This loop iterates through `jobIdToRequestId` mapping.
        // In a production environment with many jobs, consider optimizing this.
        for (uint256 i = 0; i < nextJobId; i++) {
            if (jobIdToRequestId[i] == _requestId) {
                return i;
            }
        }
        // This revert indicates a logic error or unexpected state, as every request should map to a jobId.
        revert("Internal Job ID not found for request ID");
    }


    // --- Administrative Functions (Owner Only) ---
    // These functions are callable only by the contract's administrative owner (set in constructor).

    /**
     * @dev Allows the contract owner to set/update the Chainlink Functions Router address.
     * This is useful for migrating to a new router contract or correcting the address after deployment.
     * Only callable by the contract owner.
     * @param _router The new Chainlink Functions Router address.
     */
    function setFunctionsRouter(address _router) public onlyOwner {
        require(_router != address(0), "Router address cannot be zero");
        emit FunctionsRouterUpdated(s_functionsRouter, _router);
        s_functionsRouter = _router;
        // Update the router address in the inherited FunctionsClient base contract.
        // This is a direct call to a protected internal function from FunctionsClient.
        _setRouter(_router); // Corrected: Use _setRouter (with underscore)
    }

    /**
     * @dev Allows the contract owner to set/update the Chainlink Functions Subscription ID.
     * This is necessary if the subscription ID changes or needs to be set after deployment.
     * Only callable by the contract owner.
     * @param _subscriptionId The new Chainlink Functions Subscription ID.
     */
    function setFunctionsSubscriptionId(uint64 _subscriptionId) public onlyOwner {
        require(_subscriptionId > 0, "Subscription ID must be greater than zero");
        emit FunctionsSubscriptionUpdated(s_functionsSubscriptionId, _subscriptionId);
        s_functionsSubscriptionId = _subscriptionId;
    }

    /**
     * @dev Allows the contract owner to set/update the Chainlink Functions Callback Gas Limit.
     * This value can be adjusted based on the complexity and gas consumption of the `fulfill` function's logic.
     * Only callable by the contract owner.
     * @param _newLimit The new callback gas limit.
     */
    function setCallbackGasLimit(uint32 _newLimit) public onlyOwner {
        require(_newLimit > 0, "Callback gas limit must be greater than zero");
        emit CallbackGasLimitUpdated(s_callbackGasLimit, _newLimit);
        s_callbackGasLimit = _newLimit;
    }

    
}
