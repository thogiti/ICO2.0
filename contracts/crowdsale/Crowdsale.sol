pragma solidity ^0.4.23;

import "../token/CustomToken.sol";
import "../fund/Fund.sol";
import "../lib/SafeMath.sol";
import "../ownership/Ownable.sol";
import "../token/VestingTokens.sol";
/**
 * @title Crowdsale
 * @dev Crowdsale is a base contract for managing a token crowdsale.
 * Crowdsales have a start and end timestamps, where investors can make
 * token purchases and the crowdsale will assign them tokens based
 * on a token per ETH rate. Funds collected are forwarded to a wallet
 * as they arrive. The contract requires a MintableToken that will be
 * minted as contributions arrive, note that the crowdsale contract
 * must be owner of the token in order to be able to mint it.
 */
contract Crowdsale is Ownable {
    /* Library and Typedefs */
    using SafeMath for uint256;
    enum STATE {PREPARE, ACTIVE, FINISHED}
    /* Constants */
    uint public constant HARD_CAP = 37500 ether;
    uint public constant MIN_CONTRIB = 5000 ether;

    //percentage of tokens
    uint public constant PUB_TOKEN_PERC = 20;
    uint public constant PRIV_TOKEN_PERC = 20;
    uint public constant RESERVE_TOKEN_PERC = 20;
    uint public constant REWARD_TOKEN_PERC = 20;
    uint public constant DEV_TOKEN_PERC = 14;
    uint public constant ADV_TOKEN_PERC = 5;
    uint public constant INCENTIVE_TOKEN_PERC = 1;

    //limitation of public participants
    uint public constant ETHER_MIN_CONTRIB = 1 ether;
    uint public constant ETHER_MAX_CONTRIB = 300 ether;

    //crowd sale time
    uint public constant SALE_START_TIME = 0;
    uint public constant SALE_END_TIME = 0;

    // how many token units a buyer gets per wei
    uint public constant DEFAULT_RATE = 50*10**5; //this is ether/token or wei/tokenWei

    /* Global Variables */
    CustomToken public mToken; //address
    Fund public mFund; // ether bank, it should be Fund.sol's Contract address
    VestingTokens public mVestingTokens;

    uint public mCurrentAmount;
    //discount rate -20%(~1/8) => -15%(~2/8) => -10%(~3/8) => -5%(~4/8) =>0%(~8/8)
    uint public mCurrentDiscountPerc = 20; //inital discount rate
    STATE public mCurrentState = STATE.PREPARE;

    //index => address => amount set of crowdsale participants
    mapping(address => uint) public mPrivateSale;
    mapping(address => uint) public mDevelopers;
    mapping(address => uint) public mAdvisors;
    mapping(address => uint) public mUserContributed;
    address[] public mPrivateSaleIndex;
    address[] public mDevelopersIndex;
    address[] public mAdvisorsIndex;
    address[] public mUserContributedIndex;

    /* Events */
    event TokenPurchase(address indexed purchaser, address indexed beneficiary, uint256 wei_amount, uint256 token_amount, bool success);
    event StoreEtherToWallet(address indexed purchaser, address indexed wallet_address, uint256 wei_amount, uint256 token_amount, bool success);
    event EtherChanges(address indexed purchaser, uint value); // send back ETH changes
    //event GoalReached(uint256 endtime, uint256 total_amount);
    /* Modifiers */
    modifier isSalePreparing(){
        require(mCurrentState == STATE.PREPARE, "Not Preparing");
        _;
    }
    modifier isSaleActive() {
        require(mCurrentState == STATE.ACTIVE, "Not Active");
        _;
    }
    modifier isSaleFinished(){
        require(mCurrentState == STATE.FINISHED, "Not Finished");
        _;
    }
    /* Constructor */
    constructor(
        address _tokenAddress,
        address _fundAddress
        ) public Ownable(msg.sender) {
        require(_fundAddress != address(0));
        require(_tokenAddress != address(0));

        mFund = Fund(_fundAddress);
        mToken = CustomToken(_tokenAddress);
        mFund.startSale(); //external function in Fund.sol
    }

    /* Fallback Function */
    function () external payable {
        buyTokens(msg.sender);
    }
    /* View Function */
    function getStartTime() view public returns(uint256) { return SALE_START_TIME; }
    function getEndTime() view public returns(uint256) { return SALE_END_TIME; }
    function getFundingGoal() view public returns(uint256) { return HARD_CAP; }
    function getCurrentAmount() view public returns(uint256) { return mCurrentAmount; }
    //divide type and check amount of current locked tokens
    function getLockedAmount(VestingTokens.LOCK_TYPE _type) view public returns(uint256){
        uint i = 0;
        uint sum = 0;
        address[] memory targetIndex;
        mapping(address => uint) memory target;
        uint percentage;
        if(_type == VestingTokens.LOCK_TYPE.DEV){
            targetIndex = mDevelopersIndex;
            target = mDevelopers;
            percentage = DEV_TOKEN_PERC;
        } else if(_type == VestingTokens.LOCK_TYPE.ADV){
            targetIndex = mAdvisorsIndex;
            target = mAdvisors;
            percentage = ADV_TOKEN_PERC;
        } else if(_type == VestingTokens.LOCK_TYPE.PRIV){
            targetIndex = mPrivateSaleIndex;
            target = mPrivateSale;
            percentage = PRIV_TOKEN_PERC;
        } else
            revert("Wrong Type");
        for (i = 0; i < targetIndex.length; i++) {
            sum += target[targetIndex[i]];
        }
        return sum;
    }
    function getCurrentSate() view external returns(string){
        if(mCurrentState == STATE.PREPARING){
            return "PREPARING";
        } else if(mCurrentState == STATE.ACTIVE){
            return "ACTIVE";
        } else if(mCurrentState == STATE.FINISHED){
            return "FINISHED";
        } else
            return "SOMETHING WORNG";
    }
    // Business logic could be described here or getRate()
    function getTokenAmount(uint256 weiAmount) internal view returns (uint256) {
        return weiAmount.mul(getRate());
    }
    /* Change CrowdSale State, call only once */
    function activateSale() public onlyOwner isSalePreparing{
        require(now >= SALE_START_TIME && now <= SALE_END_TIME, "Worng Time");
        mCurrentState = STATE.ACTIVE;
    }
    function _finishSale() private isSaleActive{
        mCurrentState = STATE.FINISHED;
    }
    function finalizeSale() public onlyOwner isSaleFinished {
        //do finalizing
    }
    // get current rate including the dicount percentage
    function getRate() public view returns (uint){
        uint rate = DEFAULT_RATE;
        if(mCurrentDiscountPerc == 0){
            return rate;
        } else{
            return rate.mul(100).div(100 - mCurrentDiscountPerc);
        }
    }
    // calculate next cap
    // Override this with custom calculation
    function getNextCap() public view returns(uint){
        require(mCurrentDiscountPerc > 0, "No Discount Any More");
        return HARD_CAP.mul(5 - mCurrentDiscountPerc/5).div(8);
    } 
    // function which checks the amount would be over next cap
    function isOver(uint _weiAmount) public view returns(bool){
        if(mCurrentDiscountPerc == 0){
            if(address(this).balance.add(_weiAmount) >= HARD_CAP){
                return true;
            } else{
                return false;
            }
        }
        if(address(this).balance.add(_weiAmount) >= getNextCap()){
            return true;
        } else{
            return false;
        }
    }
    //check the percentage of locked tokens filled;
    function isLockFilled() public view returns(bool){
        uint currentLockedAmount = getLockedAmount(VestingTokens.LOCK_TYPE.DEV);
        if(currentLockedAmount < mToken.totalSupply().div(100).mul(DEV_TOKEN_PERC)){
            revert("Developers Not Filled : "+mToken.totalSupply().div(100).mul(DEV_TOKEN_PERC).sub(currentLockedAmount));
        }
        currentLockedAmount = getLockedAmount(VestingTokens.LOCK_TYPE.ADV);
        if(currentLockedAmount < mToken.totalSupply().div(100).mul(ADV_TOKEN_PERC)){
            revert("Advisors Not Filled : "+mToken.totalSupply().div(100).mul(ADV_TOKEN_PERC).sub(currentLockedAmount));
        }
        currentLockedAmount = getLockedAmount(VestingTokens.LOCK_TYPE.PRIV);
        if(currentLockedAmount < mToken.totalSupply().div(100).mul(PRIV_TOKEN_PERC)){
            revert("PrivateSale Not Filled : "+mToken.totalSupply().div(100).mul(PRIV_TOKEN_PERC).sub(currentLockedAmount));
        }
        return true;
    }

    /* Token Purchase Function */
    function buyTokens(address _beneficiary) public payable isSaleActive {
        require(_beneficiary != address(0));

        uint weiAmount = msg.value;
        // calculate token amount to be created
        uint tokens;
        bool get_ether_success;
        bool send_token_success;
        if(!isOver(weiAmount)){ //check if estimate ether exceeds next cap
            tokens = getTokenAmount(weiAmount);
            send_token_success = mToken.transfer(_beneficiary, tokens);
            emit TokenPurchase(msg.sender, _beneficiary, weiAmount, tokens, send_token_success);
        } else{
            //when estimate ether exceeds next cap
            //we divide input ether by next cap
            uint ether1;
            uint ether2;
            if(mCurrentDiscountPerc > 0){
                // When discount rate should be changed
                ether2 = address(this).balance.add(weiAmount).sub(getNextCap()); //(balance + weiAmount) - NEXT_CAP
                ether1 = weiAmount.sub(ether2);
                tokens = getTokenAmount(ether1);
                send_token_success = mToken.transfer(_beneficiary, tokens);
                emit TokenPurchase(msg.sender, _beneficiary, ether1, tokens, send_token_success);

                mCurrentDiscountPerc = mCurrentDiscountPerc.sub(5); // Update discount percentage
                uint additionalTokens = getTokenAmount(ether2);
                send_token_success = mToken.transfer(_beneficiary, additionalTokens);
                emit TokenPurchase(msg.sender, _beneficiary, ether2, additionalTokens, send_token_success);
                tokens = tokens.add(additionalTokens);
            } else if(mCurrentDiscountPerc == 0){
                // Do when CrowdSale Ended
                ether2 = address(this).balance.add(weiAmount).sub(HARD_CAP);
                ether1 = weiAmount.sub(ether2);
                tokens = getTokenAmount(ether1);

                send_token_success = mToken.transfer(_beneficiary, tokens);
                emit TokenPurchase(msg.sender, _beneficiary, ether1, tokens, send_token_success);
                msg.sender.transfer(ether2); //pay back
                emit EtherChanges(msg.sender, ether2);
                get_ether_success = _forwardFunds(ether1);
                emit StoreEtherToWallet(msg.sender, address(mFund), ether1, tokens, get_ether_success);
                //add to map
                if(mUserContributed[_beneficiary] > 0){
                    mUserContributed[_beneficiary] = mUserContributed[_beneficiary].add(tokens);
                } else{
                    mUserContributed[_beneficiary] = tokens;
                    mUserContributedIndex.push(_beneficiary);
                }
                _finishSale();
                //finalize CrowdSale
                return;
            } else{
                revert("DiscountRate should be positive");
            }
        }
        get_ether_success = _forwardFunds(weiAmount);
        emit StoreEtherToWallet(msg.sender, address(mFund), weiAmount, tokens, get_ether_success);
        //add to map
        if(mUserContributed[_beneficiary] > 0){
            mUserContributed[_beneficiary] = mUserContributed[_beneficiary].add(tokens);
        } else{
            mUserContributed[_beneficiary] = tokens;
            mUserContributedIndex.push(_beneficiary);
        }
    }
    
    //setting vesting token address only once
    function setVestingTokens(address _vestingTokensAddress) public onlyOwner isSalePreparing {
        require(mVestingTokens == address(0)); //only once
        mVestingTokens = VestingTokens(_vestingTokensAddress);
    }
    //add developers, advisors, privateSale
    //check if it exceeds percentage
    function addToDevelopers(address _address, uint _amount) public onlyOwner{
        require(_address != address(0) && _amount > 0);
        uint currentLockedAmount = getLockedAmount(VestingTokens.LOCK_TYPE.DEV);
        require(currentLockedAmount.add(_amount) <= mToken.totalSupply().div(100).mul(DEV_TOKEN_PERC), "Over!");
        if(mDevelopers[_address] > 0){
            mDevelopers[_address] = mDevelopers[_address].add(_amount);
        } else{
            mDevelopers[_address] = _amount;
            mDevelopersIndex.push(_address);
        }
    }
    function addToAdvisors(address _address, uint _amount) public onlyOwner{
        require(_address != address(0) && _amount > 0);
        uint currentLockedAmount = getLockedAmount(VestingTokens.LOCK_TYPE.ADV);
        require(currentLockedAmount.add(_amount) <= mToken.totalSupply().div(100).mul(ADV_TOKEN_PERC), "Over!");
        if(mAdvisors[_address] > 0){
            mAdvisors[_address] = mAdvisors[_address].add(_amount);
        } else{
            mAdvisors[_address] = _amount;
            mAdvisorsIndex.push(_address);
        }
    }
    function addToPrivateSale(address _address, uint _amount) public onlyOwner{
        require(_address != address(0) && _amount > 0);
        uint currentLockedAmount = getLockedAmount(VestingTokens.LOCK_TYPE.PRIV);
        require(currentLockedAmount.add(_amount) <= mToken.totalSupply().div(100).mul(PRIV_TOKEN_PERC), "Over!");
        if(mPrivateSale[_address] > 0){
            mPrivateSale[_address] = mPrivateSale[_address].add(_amount);
        } else{
            mPrivateSale[_address] = _amount;
            mPrivateSaleIndex.push(_address);
        }
    }

    // call after finalize, only call once
    function _lockup() private {
        //check crowdsale ended
        uint i = 0;
        for (i = 0; i < mPrivateSaleIndex.length; i++) {
            mVestingTokens.lockup(
                mPrivateSaleIndex[i],
                mPrivateSale[mPrivateSaleIndex[i]],
                VestingTokens.LOCK_TYPE.PRIV
            );
        }
        for (i = 0; i < mDevelopersIndex.length; i++) {
            mVestingTokens.lockup(
                mDevelopersIndex[i],
                mDevelopers[mDevelopersIndex[i]],
                VestingTokens.LOCK_TYPE.DEV
            );
        }
        for (i = 0; i < mAdvisorsIndex.length; i++) {
            mVestingTokens.lockup(
                mAdvisorsIndex[i],
                mAdvisors[mAdvisorsIndex[i]],
                VestingTokens.LOCK_TYPE.ADV
            );
        }
        //send Vesting tokens to VestingTokens.sol
        token.transfer(mVestingTokens, mToken.totalSupply().div(100).mul(DEV_TOKEN_PERC + ADV_TOKEN_PERC + PRIV_TOKEN_PERC));
    }

    // send ether to the fund collection wallet
    // override to create custom fund forwarding mechanisms
    function _forwardFunds(uint wei_amount) private returns (bool){
        require(msg.value == wei_amount);
        address(mFund).transfer(msg.value);
        return true;
    }
    function _dividePool() internal onlyOwner {
        mFund.dividePoolAfterSale();
    }
    function finalizeFunds() public onlyOwner isSaleFinished{
        mFund.finalizeSale();
        _dividePool();
        //close sale
        //give initial fund
        //Refund vote activate
        //set tapVoting available
        //start lock counting
    }
}
