// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0 <0.9.0;

contract EscrowContract {
    struct Investment {
        uint amount;
        uint equityPercentage;
        uint fundingDeadline;
        string startupName;
        string description;
        uint valuation;
        address payable investor;
        address payable startup;
        bool active;
        bool repaid;
        bool funded;
    }

    mapping(uint => Investment) public investments;
    uint public investmentCount;

    event InvestmentCreated(
        uint investmentId,
        uint amount,
        uint equityPercentage,
        uint fundingDeadline,
        string startupName,
        string description,
        uint valuation,
        address investor,
        address startup
    );

    event InvestmentFunded(uint investmentId, address funder, uint amount);
    event InvestmentRepaid(uint investmentId, uint amount);

    modifier onlyActiveInvestment(uint _investmentId) {
        require(investments[_investmentId].active, "Investment is not active");
        _;
    }

    modifier onlyInvestor(uint _investmentId) {
        require(
            msg.sender == investments[_investmentId].investor,
            "Only the investor can perform this action"
        );
        _;
    }

    function createInvestment(
        uint _amount,
        uint _equityPercentage,
        string memory _startupName,
        string memory _description,
        uint _valuation
    ) external payable {
        uint _fundingDeadline = block.timestamp + (1 days);
        uint investmentId = investmentCount++;

        Investment storage investment = investments[investmentId];
        investment.amount = _amount;
        investment.equityPercentage = _equityPercentage;
        investment.fundingDeadline = _fundingDeadline;
        investment.startupName = _startupName;
        investment.description = _description;
        investment.valuation = _valuation;
        investment.investor = payable(msg.sender);
        investment.startup = payable(address(0));
        investment.active = true;
        investment.repaid = false;
        investment.funded = false;

        emit InvestmentCreated(
            investmentId,
            _amount,
            _equityPercentage,
            _fundingDeadline,
            _startupName,
            _description,
            _valuation,
            msg.sender,
            address(0)
        );
    }

    function fundInvestment(
        uint _investmentId
    ) external payable onlyActiveInvestment(_investmentId) {
        Investment storage investment = investments[_investmentId];
        require(
            msg.sender != investment.investor,
            "Investor cannot fund their own investment"
        );
        require(investment.amount == msg.value, "Incorrect investment amount");
        require(
            block.timestamp <= investment.fundingDeadline,
            "Investment funding deadline has passed"
        );
        require(!investment.funded, "Investment has already been funded");

        investment.startup = payable(msg.sender);
        investment.active = false;
        investment.funded = true;

        emit InvestmentFunded(_investmentId, msg.sender, msg.value);
    }

    function pauseInvestment(uint _investmentId) external {
        Investment storage investment = investments[_investmentId];
        require(
            msg.sender == investment.investor ||
                msg.sender == investment.startup,
            "Only the investor or the startup can pause the investment"
        );
        require(investment.active, "Investment is not active");

        investment.active = false;
    }

    function resumeInvestment(uint _investmentId) external {
        Investment storage investment = investments[_investmentId];
        require(
            msg.sender == investment.investor ||
                msg.sender == investment.startup,
            "Only the investor or the startup can resume the investment"
        );
        require(!investment.active, "Investment is already active");

        investment.active = true;
    }

    function repayInvestment(
        uint _investmentId
    )
        external
        payable
        onlyActiveInvestment(_investmentId)
        onlyInvestor(_investmentId)
    {
        Investment storage investment = investments[_investmentId];
        require(msg.value == investment.amount, "Incorrect repayment amount");
        require(!investment.repaid, "Investment has already been repaid");

        investment.startup.transfer(msg.value);
        investment.repaid = true;
        investment.active = false;

        emit InvestmentRepaid(_investmentId, msg.value);
    }

    function extendFundingDeadline(
        uint _investmentId,
        uint _extensionDuration
    ) external {
        Investment storage investment = investments[_investmentId];
        require(investment.active, "Investment is not active");
        require(investment.funded, "Investment has not been funded");
        require(
            msg.sender == investment.startup,
            "Only the startup can extend the funding deadline"
        );

        // Calculate the new funding deadline by adding the extension duration to the current deadline
        uint newDeadline = investment.fundingDeadline + _extensionDuration;

        // Update the funding deadline
        investment.fundingDeadline = newDeadline;
    }

    function getInvestmentInfo(
        uint _investmentId
    )
        external
        view
        returns (
            uint amount,
            uint equityPercentage,
            uint fundingDeadline,
            string memory startupName,
            string memory description,
            uint valuation,
            address investor,
            address startup,
            bool active,
            bool repaid,
            bool funded
        )
    {
        Investment storage investment = investments[_investmentId];
        return (
            investment.amount,
            investment.equityPercentage,
            investment.fundingDeadline,
            investment.startupName,
            investment.description,
            investment.valuation,
            investment.investor,
            investment.startup,
            investment.active,
            investment.repaid,
            investment.funded
        );
    }

    function withdrawFunds(
        uint _investmentId
    ) external onlyInvestor(_investmentId) {
        Investment storage investment = investments[_investmentId];
        require(!investment.active, "Investment is still active");

        payable(msg.sender).transfer(investment.amount);
    }
}
