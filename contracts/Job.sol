// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IAgentRegistry.sol";
import "./interfaces/IJob.sol";

import "@chainlink/contracts/src/v0.8/functions/dev/v1_0_0/FunctionsClient.sol";
import "@chainlink/contracts/src/v0.8/shared/access/ConfirmedOwnerWithProposal.sol";
import "@chainlink/contracts/src/v0.8/functions/dev/v1_0_0/libraries/FunctionsRequest.sol";

contract Job is IJob, FunctionsClient, ConfirmedOwnerWithProposal {
    using FunctionsRequest for FunctionsRequest.Request;

    IAgentRegistry public immutable agentRegistry;
    uint64 public s_functionsSubscriptionId;
    uint32 public s_callbackGasLimit = 300000;
    address private s_router;

    mapping(bytes32 => JobDetails) public jobs;
    mapping(uint256 => bytes32) public jobIdToRequestId;
    uint256 public nextJobId;

    constructor(
        address _agentRegistry,
        address _functionsRouter,
        uint64 _subscriptionId,
        address initialOwner
    ) ConfirmedOwnerWithProposal(initialOwner, initialOwner) FunctionsClient(_functionsRouter) {
        require(_agentRegistry != address(0), "AgentRegistry required");
        require(_functionsRouter != address(0), "Router required");
        require(_subscriptionId > 0, "Invalid subscription ID");

        agentRegistry = IAgentRegistry(_agentRegistry);
        s_router = _functionsRouter;
        s_functionsSubscriptionId = _subscriptionId;
    }

    function acceptOwnership() public override(ConfirmedOwnerWithProposal, IJob) {
        super.acceptOwnership();
    }

    function owner() public view override(ConfirmedOwnerWithProposal, IJob) returns (address) {
        return ConfirmedOwnerWithProposal.owner();
    }

    function transferOwnership(address newOwner) public override(ConfirmedOwnerWithProposal, IJob) {
        ConfirmedOwnerWithProposal.transferOwnership(newOwner);
    }

    function fulfill(bytes32 requestId, bytes memory response, bytes memory err) external override {
        revert("fulfill not yet implemented");
    }

    function s_functionsRouter() external view override returns (address) {
        return s_router;
    }

    function setFunctionsRouter(address _router) external override onlyOwner {
        require(_router != address(0), "Router cannot be zero address");
        s_router = _router;
    }

    function _sendRequest(
        string memory source,
        bytes memory encryptedSecretsReference,
        string[] memory args,
        uint64 subscriptionId,
        uint32 callbackGasLimit,
        bytes32 donId
    ) internal returns (bytes32 requestId) {
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(source);

        if (encryptedSecretsReference.length > 0) {
            req.addSecretsReference(encryptedSecretsReference);
        }

        if (args.length > 0) {
            req.setArgs(args);
        }

        bytes memory requestData = req.encodeCBOR();
        return FunctionsClient._sendRequest(requestData, subscriptionId, callbackGasLimit, donId);
    }

    function createJob(
        uint256 _agentId,
        string memory _inputData,
        string calldata _source,
        bytes calldata _secrets,
        string[] calldata _args
    ) public payable returns (uint256) {
        IAgentRegistry.Agent memory agent = agentRegistry.agents(_agentId);
        require(agent.registered, "Unregistered agent");
        require(msg.value == agent.price, "Incorrect payment");
        require(bytes(_inputData).length > 0, "Empty input");
        require(bytes(_source).length > 0, "Empty source");

        uint256 jobId = nextJobId++;
        string[] memory args = _buildArgs(agent.endpointUrl, _inputData, _args);

        bytes32 requestId = _sendRequest(
            _source,
            _secrets,
            args,
            s_functionsSubscriptionId,
            s_callbackGasLimit,
            bytes32("functions-arbitrum-sepolia-1")
        );

        _storeJob(_agentId, _inputData, requestId, msg.value, msg.sender);
        jobIdToRequestId[jobId] = requestId;

        emit JobCreated(jobId, _agentId, msg.sender, msg.value, _inputData, requestId);
        return jobId;
    }

    function _buildArgs(string memory endpointUrl, string memory inputData, string[] calldata userArgs)
        internal pure returns (string[] memory)
    {
        string[] memory args = new string[](userArgs.length + 2);
        args[0] = endpointUrl;
        args[1] = inputData;
        for (uint256 i = 0; i < userArgs.length; i++) {
            args[i + 2] = userArgs[i];
        }
        return args;
    }

    function _storeJob(
        uint256 agentId,
        string memory inputData,
        bytes32 requestId,
        uint256 payment,
        address sender
    ) internal {
        jobs[requestId] = JobDetails({
            agentId: agentId,
            user: sender,
            paymentAmount: payment,
            inputData: inputData,
            outputData: "",
            status: JobStatus.Pending,
            requestId: requestId,
            rawResponse: "",
            rawError: ""
        });
    }

    function fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {
        JobDetails storage job = jobs[requestId];
        require(job.status == JobStatus.Pending, "Already fulfilled");

        job.rawResponse = response;
        job.rawError = err;

        if (err.length > 0) {
            _refundUser(job, getInternalJobId(requestId), string(err));
            return;
        }

        if (response.length > 0) {
            string memory output = abi.decode(response, (string));
            job.outputData = output;
            job.status = JobStatus.Fulfilled;

            IAgentRegistry.Agent memory agent = agentRegistry.agents(job.agentId);
            (bool success, ) = agent.owner.call{value: job.paymentAmount}("");
            require(success, "Agent payment failed");
            emit JobFulfilled(getInternalJobId(requestId), output, requestId);
        } else {
            _refundUser(job, getInternalJobId(requestId), "Decoding failed");
        }
    }

    function _refundUser(JobDetails storage job, uint256 jobId, string memory reason) internal {
        job.status = JobStatus.Failed;
        (bool refunded, ) = job.user.call{value: job.paymentAmount}("");
        require(refunded, "Refund failed");
        emit JobFailed(jobId, reason, job.requestId);
    }

    function getInternalJobId(bytes32 requestId) internal view returns (uint256) {
        for (uint256 i = 0; i < nextJobId; i++) {
            if (jobIdToRequestId[i] == requestId) {
                return i;
            }
        }
        revert("Job ID not found");
    }

    function setFunctionsSubscriptionId(uint64 newId) external onlyOwner {
        require(newId > 0, "Invalid ID");
        emit FunctionsSubscriptionUpdated(s_functionsSubscriptionId, newId);
        s_functionsSubscriptionId = newId;
    }

    function setCallbackGasLimit(uint32 newLimit) external onlyOwner {
        require(newLimit > 0, "Invalid gas limit");
        emit CallbackGasLimitUpdated(s_callbackGasLimit, newLimit);
        s_callbackGasLimit = newLimit;
    }
}
