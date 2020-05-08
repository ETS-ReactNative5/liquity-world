pragma solidity ^0.5.11;

import "./Interfaces/ICDPManager.sol";
import "./Interfaces/IPool.sol";
import "./Interfaces/IStabilityPool.sol";
import "./Interfaces/ICLVToken.sol";
import "./Interfaces/IPriceFeed.sol";
import "./Interfaces/ISortedCDPs.sol";
import "./Interfaces/IPoolManager.sol";
import "./DeciMath.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/ownership/Ownable.sol";
import "@nomiclabs/buidler/console.sol";
// import "./Library1.sol";

contract CDPManager is Ownable, ICDPManager {
    using SafeMath for uint;

    uint constant public MCR = 1100000000000000000; // Minimal collateral ratio.
    uint constant public  CCR = 1500000000000000000; // Critical system collateral ratio. If the total system collateral (TCR) falls below the CCR, Recovery Mode is triggered.
    uint constant public MIN_COLL_IN_USD = 20000000000000000000;
    enum Status { nonExistent, active, closed }
    
    // --- Events --- 

    event PoolManagerAddressChanged(address _newPoolManagerAddress);
    event ActivePoolAddressChanged(address _activePoolAddress);
    event DefaultPoolAddressChanged(address _defaultPoolAddress);
    event StabilityPoolAddressChanged(address _stabilityPoolAddress);
    event PriceFeedAddressChanged(address  _newPriceFeedAddress);
    event CLVTokenAddressChanged(address _newCLVTokenAddress);
    event SortedCDPsAddressChanged(address _sortedCDPsAddress);

    event CDPCreated(address indexed _user, uint arrayIndex);
    event CDPUpdated(address indexed _user, uint _debt, uint _coll, uint stake);
   
    // --- Connected contract declarations ---

    IPoolManager poolManager;
    address public poolManagerAddress;

    IPool activePool;
    address public activePoolAddress;

    IPool defaultPool;
    address public defaultPoolAddress;

    ICLVToken CLV; 
    address public clvTokenAddress;

    IPriceFeed priceFeed;
    address public priceFeedAddress;

    IStabilityPool stabilityPool;
    address public stabilityPoolAddress;

    // A doubly linked list of CDPs, sorted by their sorted by their collateral ratios
    ISortedCDPs sortedCDPs;
    address public sortedCDPsAddress;

    // --- Data structures ---

    // Store the necessary data for a Collateralized Debt Position (CDP)
    struct CDP {
        uint debt;
        uint coll;
        uint stake;
        Status status;
        uint arrayIndex;
    }

    mapping (address => CDP) public CDPs;

    uint public totalStakes; 

    // snapshot of the value of totalStakes immediately after the last liquidation
    uint public totalStakesSnapshot;  

    // snapshot of the total collateral in ActivePool and DefaultPool, immediately after the last liquidation.
    uint public totalCollateralSnapshot;    

    /* L_ETH and L_CLVDebt track the sums of accumulated liquidation rewards per unit staked. During it's lifetime, each stake earns:

    An ETH gain of ( stake * [L_ETH - L_ETH(0)] )
    A CLVDebt gain  of ( stake * [L_CLVDebt - L_CLVDebt(0)] )
    
    Where L_ETH(0) and L_CLVDebt(0) are snapshots of L_ETH and L_CLVDebt for the active CDP taken at the instant the stake was made */
    uint public L_ETH;     
    uint public L_CLVDebt;    

    // Map addresses with active CDPs to their RewardSnapshot
    mapping (address => RewardSnapshot) public rewardSnapshots;  

    // Object containing the ETH and CLV snapshots for a given active CDP
    struct RewardSnapshot { uint ETH; uint CLVDebt;}   

    // Array of all active CDP addresses - used to compute “approx hint” for list insertion
    address[] CDPOwners;

    // Error trackers for the trove redistribution calculation
    uint lastETHError_Redistribution;
    uint lastCLVDebtError_Redistribution;

    // --- Modifiers ---

    modifier onlyPoolManager {
        require(_msgSender() == poolManagerAddress, "CDPManager: Only the poolManager is authorized");
        _;
    }

    // --- Dependency setters --- 

    function setPoolManager(address _poolManagerAddress) public onlyOwner {
        poolManagerAddress = _poolManagerAddress;
        poolManager = IPoolManager(_poolManagerAddress);
        emit PoolManagerAddressChanged(_poolManagerAddress);
    }

    function setActivePool(address _activePoolAddress) public onlyOwner {
        activePoolAddress = _activePoolAddress;
        activePool = IPool(_activePoolAddress);
        emit ActivePoolAddressChanged(_activePoolAddress);
    }

    function setDefaultPool(address _defaultPoolAddress) public onlyOwner {
        defaultPoolAddress = _defaultPoolAddress;
        defaultPool = IPool(_defaultPoolAddress);
        emit DefaultPoolAddressChanged(_defaultPoolAddress);
    }

    function setStabilityPool(address _stabilityPoolAddress) public onlyOwner {
        stabilityPoolAddress = _stabilityPoolAddress;
        stabilityPool = IStabilityPool(_stabilityPoolAddress);
        emit StabilityPoolAddressChanged(_stabilityPoolAddress);
    }

    function setPriceFeed(address _priceFeedAddress) public onlyOwner {
        priceFeedAddress = _priceFeedAddress;
        priceFeed = IPriceFeed(priceFeedAddress);
        emit PriceFeedAddressChanged(_priceFeedAddress);
    }

    function setCLVToken(address _clvTokenAddress) public onlyOwner {
        clvTokenAddress = _clvTokenAddress;
        CLV = ICLVToken(_clvTokenAddress);
        emit CLVTokenAddressChanged(_clvTokenAddress);
    }

    function setSortedCDPs(address _sortedCDPsAddress) public onlyOwner {
        sortedCDPsAddress = _sortedCDPsAddress;
        sortedCDPs = ISortedCDPs(_sortedCDPsAddress);
        emit SortedCDPsAddressChanged(_sortedCDPsAddress);
    }

    // --- Getters ---
    
    function getCDPOwnersCount() public view returns(uint) {
        return CDPOwners.length;
    }
    
    // --- Borrower CDP Operations ---

    function openLoan(uint _CLVAmount, address _hint) public payable returns (bool) {
        uint price = priceFeed.getPrice(); 
        address user = _msgSender(); 
       
        requireValueIsGreaterThan20Dollars(msg.value, price);
        
        uint ICR = computeICR(msg.value, _CLVAmount, price);  

        if (_CLVAmount > 0) {
            requireNotInRecoveryMode();
            requireICRisAboveMCR(ICR);

            uint newTCR = getNewTCR(msg.value, _CLVAmount, price); 
            requireTCRisAboveCCR(newTCR);
        }
        
        // Update loan properties
        CDPs[user].status = Status.active;  
        CDPs[user].coll = msg.value;  
        CDPs[user].debt = _CLVAmount; 
       
        updateRewardSnapshots(user); 
        updateStakeAndTotalStakes(user); 
        
        sortedCDPs.insert(user, ICR, price, _hint, _hint); 
        
        /* Push the owner's address to the CDP owners list, and record 
        the corresponding array index on the CDP struct */
        CDPs[user].arrayIndex = CDPOwners.push(user) - 1; 
        
        // Move the ether to the Active Pool, and mint CLV to the borrower
        poolManager.addColl.value(msg.value)(); 
    
        poolManager.withdrawCLV(user, _CLVAmount); 
       
        emit CDPUpdated(user, 
                        _CLVAmount, 
                        msg.value,
                        CDPs[user].stake
                        ); 
        return true;
    }

    // Send ETH as collateral to a CDP
    function addColl(address _user, address _hint) public payable returns (bool) {
        bool isFirstCollDeposit;
        uint price = priceFeed.getPrice();
       
        Status status = CDPs[_user].status;
    
        if (status == Status.nonExistent || status == Status.closed ) {
            requireValueIsGreaterThan20Dollars(msg.value, price);

            isFirstCollDeposit = true; 
            CDPs[_user].status = Status.active;
        } 

        applyPendingRewards(_user);
       
        // Update the CDP's coll and stake
        uint newColl = (CDPs[_user].coll).add(msg.value);
        CDPs[_user].coll = newColl;

        updateStakeAndTotalStakes(_user);
        
        uint newICR = getCurrentICR(_user, price);
   
        if (isFirstCollDeposit) { 
            sortedCDPs.insert(_user, newICR, price, _hint, _hint);
             /* push the owner's address to the CDP owners list, and record 
            the corresponding array index on the CDP struct */
            CDPs[_user].arrayIndex = CDPOwners.push(_user) - 1;
            emit CDPCreated(_user, CDPs[_user].arrayIndex);
        } else {
            sortedCDPs.reInsert(_user, newICR, price, _hint, _hint);  
        }

        // Send the received collateral to PoolManager, to forward to ActivePool
        poolManager.addColl.value(msg.value)();
  
        emit CDPUpdated(_user, 
                        CDPs[_user].debt, 
                        newColl,
                        CDPs[_user].stake
                        );
        return true;
    }
    
    // Withdraw ETH collateral from a CDP
    function withdrawColl(uint _amount, address _hint) public returns (bool) {
        uint price = priceFeed.getPrice();
        
        address user = _msgSender();
        requireCDPisActive(user);
        requireNotInRecoveryMode();
       
        applyPendingRewards(user);

        uint coll = CDPs[user].coll;
        uint newColl = coll.sub(_amount);
        
       requireCollAmountIsWithdrawable(coll, newColl, price);

        uint newICR = getNewICRfromCollDecrease(user, _amount, price); 
        requireICRisAboveMCR(newICR);
        
        // Update the CDP's coll and stake
        CDPs[user].coll = newColl;
        updateStakeAndTotalStakes(user);

        if (newColl == 0) { 
             closeCDP(user);  
        }  else { 
        // Update CDP's position in sortedCDPs
            sortedCDPs.reInsert(user, newICR, price, _hint, _hint);
            emit CDPUpdated(user, 
                            CDPs[user].debt, 
                            newColl,
                            CDPs[user].stake
                            ); 
        }
         // Remove _amount ETH from ActivePool and send it to the user
        poolManager.withdrawColl(user, _amount);

        return true;
    }
    
    // Withdraw CLV tokens from a CDP: mint new CLV to the owner, and increase the debt accordingly
    function withdrawCLV(uint _amount, address _hint) public returns (bool) {
        uint price = priceFeed.getPrice();
    
        address user = _msgSender();
        
        requireCDPisActive(user);
        requireNonZeroAmount(_amount); 
        requireNotInRecoveryMode();
        
        applyPendingRewards(user);

        uint newICR = getNewICRfromDebtIncrease(user, _amount, price);
        uint newTCR = getNewTCR(0, _amount, price);

        requireICRisAboveMCR(newICR);
        requireTCRisAboveCCR(newTCR);
        
        // Increase the CDP's debt
        uint newDebt = (CDPs[user].debt).add(_amount);
        CDPs[user].debt = newDebt;

        // Update CDP's position in sortedCDPs
        sortedCDPs.reInsert(user, newICR, price, _hint, _hint);

        // Mint the given amount of CLV to the owner's address and add them to the ActivePool
        poolManager.withdrawCLV(user, _amount);
        
        emit CDPUpdated(user, 
                        newDebt, 
                        CDPs[user].coll, 
                        CDPs[user].stake
                        ); 
        return true; 
    }
    
    // Repay CLV tokens to a CDP: Burn the repaid CLV tokens, and reduce the debt accordingly
    function repayCLV(uint _amount, address _hint) public returns (bool) {
        uint price = priceFeed.getPrice();
        address user = _msgSender();
        
        requireCDPisActive(user);

        applyPendingRewards(user);

        uint debt = CDPs[user].debt;
        requireCLVRepaymentAllowed(debt, _amount);
        
        // Update the CDP's debt
        uint newDebt = debt.sub(_amount);
        CDPs[user].debt  = newDebt;

        uint newICR = getCurrentICR(user, price);
        
        // Update CDP's position in sortedCDPs
        sortedCDPs.reInsert(user, newICR, price, _hint, _hint);

        // Burn the received amount of CLV from the user's balance, and remove it from the ActivePool
        poolManager.repayCLV(user, _amount);
        
        emit CDPUpdated(user, 
                        newDebt, 
                        CDPs[user].coll,
                        CDPs[user].stake
                        ); 
        return true;
    }

    function closeLoan() public returns (bool) {
        address user = _msgSender();
        applyPendingRewards(user);

        requireCDPisActive(user);
        requireNotInRecoveryMode();
        
        uint coll = CDPs[user].coll;
        uint debt = CDPs[user].debt;

        removeStake(user);
        closeCDP(user);
    
        // Tell PM to burn the debt from the user's balance, and send the collateral back to the user
        poolManager.repayCLV(user, debt);
        poolManager.withdrawColl(user, coll);

        emit CDPUpdated(user, 0, 0, 0);
        return true; 
    }

    /* If ether is sent, the operation is considered as an increase in ether, and the first parameter 
    _collWithdrawal is ignored  */
    function adjustLoan(uint _collWithdrawal, int _debtChange, address _hint) public payable returns (bool) {
        address user = _msgSender();
        requireCDPisActive(user);
        requireNotInRecoveryMode();
        
        uint price = priceFeed.getPrice();
     
        applyPendingRewards(user);

        // If Ether is sent, grab the amount. Otherwise, grab the specified collateral withdrawal
        int collChange = (msg.value != 0) ? int(msg.value) : -int(_collWithdrawal);

        uint currentDebt = CDPs[user].debt;
        uint currentColl = CDPs[user].coll;
       
        uint newICR = getNewICRFromTroveAdjustment(user, collChange, _debtChange, price);
       
        // --- Checks --- 
        if (_debtChange > 0) {
            requireICRisAboveMCR(newICR);
            uint newTCR = getNewTCRFromTroveAdjustment(collChange, _debtChange, price);
            requireTCRisAboveCCR(newTCR);
        } else if (_debtChange < 0)  {
            requireCLVRepaymentAllowed(currentDebt, intToUint(_debtChange));
        }
        if (collChange < 0) {
            requireICRisAboveMCR(newICR);
            requireCollAmountIsWithdrawable(currentColl, _collWithdrawal, price);
        }

        //  --- Effects --- 
        // Update coll and debt based on whether they increase or decrease
        CDPs[user].debt = (_debtChange > 0) ? currentDebt.add(intToUint(_debtChange)) :  currentDebt.sub(intToUint(_debtChange));
        CDPs[user].coll = (msg.value !=0) ? currentColl.add(msg.value) :  currentColl.sub(_collWithdrawal);
        
        updateStakeAndTotalStakes(user);
       
        // Close a CDP if it is empty, otherwise, re-insert it in the sorted list
        if (CDPs[user].debt == 0 && CDPs[user].coll == 0)  {
            closeCDP(user);
        } else {
            sortedCDPs.reInsert(user, newICR, price, _hint, _hint);
        }

        //  --- Interactions ---
        if (_debtChange > 0){
            poolManager.withdrawCLV(user, intToUint(_debtChange));
        } else if (_debtChange < 0) {
            poolManager.repayCLV(user, intToUint(_debtChange));
        }

        if (msg.value > 0 ) {
            poolManager.addColl.value(msg.value)();
        } else if (msg.value == 0) {
            poolManager.withdrawColl(user, _collWithdrawal);
        }

        emit CDPUpdated(user, 
                        CDPs[user].debt,
                        CDPs[user].coll, 
                        CDPs[user].stake
                        ); 
    }

 
    

    // --- CDP Liquidation functions ---

    // Closes the CDP of the specified user if its individual collateral ratio is lower than the minimum collateral ratio.
    // TODO: Left public for initial testing. Make internal.
    function liquidate(address _user) public returns (bool) {
        uint price = priceFeed.getPrice();
        uint ICR = getCurrentICR(_user, price);
        
        bool recoveryMode = checkRecoveryMode();

        require(CDPs[_user].status == Status.active, "CDPManager: CDP does not exist or is already closed");

        if (recoveryMode == true) {
            liquidateRecoveryMode(_user, ICR, price);
        } else if (recoveryMode == false) {
            liquidateNormalMode(_user, ICR);
        }  
    }
   
    function liquidateNormalMode(address _user, uint _ICR) internal returns (bool) {
        // If ICR > MCR, don't liquidate 
        if (_ICR > MCR) { return false; }
       
        // Get the CDP's entire debt and coll, including pending rewards from distributions
        (uint entireCDPDebt, uint entireCDPColl) = getEntireDebtAndColl(_user);
        removeStake(_user); 

        uint CLVInPool = stabilityPool.getCLV();

        // Offset as much debt & collateral as possible against the Stability Pool, and redistribute the remainder
        if (CLVInPool > 0) {
            (uint CLVDebtRemainder, uint ETHRemainder) = poolManager.offset(entireCDPDebt, entireCDPColl, CLVInPool);
            redistributeDebtAndColl(CLVDebtRemainder, ETHRemainder);
        } else {
            redistributeDebtAndColl(entireCDPDebt, entireCDPColl);
        }

        closeCDP(_user);
        updateSystemSnapshots();
        emit CDPUpdated(_user, 0, 0, 0);

        return true;
    }

    function liquidateRecoveryMode(address _user, uint _ICR, uint _price) internal returns (bool) {
        // If ICR <= 100%, purely redistribute the CDP across all active CDPs
        if (_ICR <= 1000000000000000000) {
            (uint entireCDPDebt, uint entireCDPColl) = getEntireDebtAndColl(_user);
            removeStake(_user);
            
            redistributeDebtAndColl(entireCDPDebt, entireCDPColl);

            closeCDP(_user);
            updateSystemSnapshots();

        // if 100% < ICR < MCR, offset as much as possible, and redistribute the remainder
        } else if ((_ICR > 1000000000000000000) && (_ICR < MCR)) {
            (uint entireCDPDebt, uint entireCDPColl) = getEntireDebtAndColl(_user);
            removeStake(_user);
            
            uint CLVInPool = stabilityPool.getCLV();

            if (CLVInPool > 0) {
                (uint CLVDebtRemainder, uint ETHRemainder) = poolManager.offset(entireCDPDebt, entireCDPColl, CLVInPool);
                redistributeDebtAndColl(CLVDebtRemainder, ETHRemainder);
            } else {
                redistributeDebtAndColl(entireCDPDebt, entireCDPColl);
            }
    
            closeCDP(_user);
            updateSystemSnapshots();

        // If CDP has the lowest ICR and there is CLV in the Stability Pool, only offset it as much as possible (no redistribution)
        } else if (_user == sortedCDPs.getLast()) {
            
            uint CLVInPool = stabilityPool.getCLV();
            if (CLVInPool == 0) { return false; }

            applyPendingRewards(_user);
            removeStake(_user);

            (uint CLVDebtRemainder, uint ETHRemainder) = poolManager.offset(CDPs[_user].debt, 
                                                                            CDPs[_user].coll, 
                                                                            CLVInPool);
          
            // Close the CDP and update snapshots if the CDP was completely offset against CLV in Stability Pool
            if (CLVDebtRemainder == 0) {
                closeCDP(_user);
                updateSystemSnapshots();
            }

            // If loan can not be entirely offset, leave the CDP active, with a reduced coll and debt, and corresponding new stake.
            if (CLVDebtRemainder > 0) {
                // Update system snapshots, excluding the reduced collateral that remains in the CDP
                updateSystemSnapshots_excludeCollRemainder(ETHRemainder);
                
                // Give the loan a new reduced coll and debt, then update stake and totalStakes
                CDPs[_user].coll = ETHRemainder;
                CDPs[_user].debt = CLVDebtRemainder;
                updateStakeAndTotalStakes(_user);
               
                uint newICR = getCurrentICR(_user, _price);
          
                sortedCDPs.reInsert(_user, newICR, _price, _user, _user); 
            }
        } 
        emit CDPUpdated(_user, 
                    CDPs[_user].debt, 
                    CDPs[_user].coll,
                    CDPs[_user].stake
                    );

        return true;
    }

    // Closes a maximum number of n multiple under-collateralized CDPs, starting from the one with the lowest collateral ratio
    function liquidateCDPs(uint n) public returns (bool) {  
        uint price = priceFeed.getPrice();
        bool recoveryModeAtStart = checkRecoveryMode();

        if (recoveryModeAtStart == true) {
            uint i;
            bool backToNormalMode;

            while (i < n) {
                address user = sortedCDPs.getLast();
                uint collRatio = getCurrentICR(user, price);
                
                // Attempt to close CDP
                if (backToNormalMode == false) {
                    liquidateRecoveryMode(user, collRatio, price);
                    backToNormalMode = !checkRecoveryMode();
                } 
                else {
                    if (collRatio < MCR) {
                        liquidateNormalMode(user, collRatio);
                    } else break;  // break if the loop reaches a CDP with ICR >= MCR
                } 
                // Break the loop if it reaches the first CDP in the sorted list 
                if (user == sortedCDPs.getFirst()) { break ;}
                i++;
            }
            return true;

        } else if (recoveryModeAtStart == false) {
            uint i;
            while (i < n) {
                address user = sortedCDPs.getLast();
                uint collRatio = getCurrentICR(user, price);

                // Close CDPs if it is under-collateralized
                if (collRatio < MCR) {
                    liquidateNormalMode(user, collRatio);
                } else break;  // break if the loop reaches a CDP with ICR >= MCR
                
                // Break the loop if it reaches the first CDP in the sorted list 
                if (user == sortedCDPs.getFirst()) { break ;}
                i++;
            }       
        }
        return true;
    }

    // Redeem as much collateral as possible from _cdpUser's CDP in exchange for CLV up to _maxCLVamount
    function redeemCollateralFromCDP(
        address _cdpUser,
        uint _maxCLVamount,
        uint _price,
        address _partialRedemptionHint,
        uint _partialRedemptionHintICR
    )
        internal returns (uint)
    {
        // Determine the remaining amount (lot) to be redeemed, capped by the entire debt of the CDP
        uint CLVLot = DeciMath.getMin(_maxCLVamount, CDPs[_cdpUser].debt); 
        
        // Pure division to integer
        uint ETHLot = CLVLot.mul(1e18).div(_price);
        
        // Decrease the debt and collateral of the current CDP according to the lot and corresponding ETH to send
        uint newDebt = (CDPs[_cdpUser].debt).sub(CLVLot);
        uint newColl = (CDPs[_cdpUser].coll).sub(ETHLot);

        if (newDebt == 0) {
            // No debt left in the CDP, therefore new ICR must be "infinite".
            // Passing zero as hint will cause sortedCDPs to descend the list from the head, which is the correct insert position.
            sortedCDPs.reInsert(_cdpUser, 2**256 - 1, _price, address(0), address(0)); 
        } else {
            uint newICR = computeICR(newColl, newDebt, _price);

            // Check if the provided hint is fresh. If not, we bail since trying to reinsert without a good hint will almost
            // certainly result in running out of gas.
            if (newICR != _partialRedemptionHintICR) return 0;

            sortedCDPs.reInsert(_cdpUser, newICR, _price, _partialRedemptionHint, _partialRedemptionHint);
        }

        CDPs[_cdpUser].debt = newDebt;
        CDPs[_cdpUser].coll = newColl;
        updateStakeAndTotalStakes(_cdpUser);

        // Burn the calculated lot of CLV and send the corresponding ETH to _msgSender()
        poolManager.redeemCollateral(_msgSender(), CLVLot, ETHLot); 

        emit CDPUpdated(
                        _cdpUser,
                        newDebt,
                        newColl,
                        CDPs[_cdpUser].stake
                        ); 

        return CLVLot;
    }

    function validFirstRedemptionHint(address _firstRedemptionHint, uint _price) internal view returns (bool) {
        if (_firstRedemptionHint == address(0) ||
            !sortedCDPs.contains(_firstRedemptionHint) ||
            getCurrentICR(_firstRedemptionHint, _price) < MCR
        ) {
            return false;
        }

        address nextCDP = sortedCDPs.getNext(_firstRedemptionHint);
        return nextCDP == address(0) || getCurrentICR(nextCDP, _price) < MCR;
    }

    /* Send _CLVamount CLV to the system and redeem the corresponding amount of collateral from as many CDPs as are needed to fill the redemption
     request.  Applies pending rewards to a CDP before reducing its debt and coll.

    Note that if _amount is very large, this function can run out of gas. This can be easily avoided by splitting the total _amount
    in appropriate chunks and calling the function multiple times.

    All CDPs that are redeemed from -- with the likely exception of the last one -- will end up with no debt left, therefore they will be
    reinsterted at the top of the sortedCDPs list. If the last CDP does have some remaining debt, the reinsertion could be anywhere in the
    list, therefore it requires a hint. A frontend should use getRedemptionHints() to calculate what the ICR of this CDP will be
    after redemption, and pass a hint for its position in the sortedCDPs list along with the ICR value that the hint was found for.

    If another transaction modifies the list between calling getRedemptionHints() and passing the hints to redeemCollateral(), it
    is very likely that the last (partially) redeemed CDP would end up with a different ICR than what the hint is for. In this case the
    redemption will stop after the last completely redeemed CDP and the sender will keep the remaining CLV amount, which they can attempt
    to redeem later.
     */
    function redeemCollateral(
        uint _CLVamount,
        address _firstRedemptionHint,
        address _partialRedemptionHint,
        uint _partialRedemptionHintICR
    )
        public returns (bool)
    {
        uint remainingCLV = _CLVamount;
        uint price = priceFeed.getPrice();
        address currentCDPuser;

        if (validFirstRedemptionHint(_firstRedemptionHint, price)) {
            currentCDPuser = _firstRedemptionHint;
        } else {
            currentCDPuser = sortedCDPs.getLast();

            while (currentCDPuser != address(0) && getCurrentICR(currentCDPuser, price) < MCR) {
                currentCDPuser = sortedCDPs.getPrev(currentCDPuser);
            }
        }

        // Loop through the CDPs starting from the one with lowest collateral ratio until _amount of CLV is exchanged for collateral
        while (currentCDPuser != address(0) && remainingCLV > 0) {
            // Save the address of the CDP preceding the current one, before potentially modifying the list
            address nextUserToCheck = sortedCDPs.getPrev(currentCDPuser);

            applyPendingRewards(currentCDPuser);

            uint CLVLot = redeemCollateralFromCDP(
                currentCDPuser,
                remainingCLV,
                price,
                _partialRedemptionHint,
                _partialRedemptionHintICR
            );

            if (CLVLot == 0) break; // Partial redemption hint got out-of-date, therefore we could not redeem from the last CDP

            remainingCLV = remainingCLV.sub(CLVLot);
            currentCDPuser = nextUserToCheck;
        }
    }

    // --- Helper functions ---

    /* getRedemptionHints() - Helper function for redeemCollateral().
     *
     * Find the first and last CDPs that will modified by calling redeemCollateral() with the same _CLVamount and _price,
     * and return the address of the first one and the final ICR of the last one.
     */
    function getRedemptionHints(uint _CLVamount, uint _price)
        public
        view
        returns (address firstRedemptionHint, uint partialRedemptionHintICR)
    {
        uint remainingCLV = _CLVamount;
        address currentCDPuser = sortedCDPs.getLast();

        while (currentCDPuser != address(0) && getCurrentICR(currentCDPuser, _price) < MCR) {
            currentCDPuser = sortedCDPs.getPrev(currentCDPuser);
        }

        firstRedemptionHint = currentCDPuser;

        while (currentCDPuser != address(0) && remainingCLV > 0) {
            uint CLVDebt = CDPs[currentCDPuser].debt.add(computePendingCLVDebtReward(currentCDPuser));

            if (CLVDebt > remainingCLV) {
                uint ETH = CDPs[currentCDPuser].coll.add(computePendingETHReward(currentCDPuser));
                uint newDebt = CLVDebt.sub(remainingCLV);

                uint newColl = ETH.sub(remainingCLV.mul(1e18).div(_price));

                partialRedemptionHintICR = computeICR(newColl, newDebt, _price);

                break;
            } else {
                remainingCLV = remainingCLV.sub(CLVDebt);
            }

            currentCDPuser = sortedCDPs.getPrev(currentCDPuser);
        }
    }

     /* getApproxHint() - return address of a CDP that is, on average, (length / numTrials) positions away in the 
    sortedCDPs list from the correct insert position of the CDP to be inserted. 
    
    Note: The output address is worst-case O(n) positions away from the correct insert position, however, the function 
    is probabilistic. Input can be tuned to guarantee results to a high degree of confidence, e.g:

    Submitting numTrials = k * sqrt(length), with k = 15 makes it very, very likely that the ouput address will 
    be <= sqrt(length) positions away from the correct insert position.
   
    Note on the use of block.timestamp for random number generation: it is known to be gameable by miners. However, no value 
    transmission depends on getApproxHint() - it is only used to generate hints for efficient list traversal. In this case, 
    there is no profitable exploit.
    */
    function getApproxHint(uint CR, uint numTrials) public view returns(address) {
        require (CDPOwners.length >= 1, "CDPManager: sortedList must not be empty");
        uint price = priceFeed.getPrice();
        address hintAddress = sortedCDPs.getLast();
        uint closestICR = getCurrentICR(hintAddress, price);
        uint diff = getAbsoluteDifference(CR, closestICR);
        uint i = 1;

        while (i < numTrials) {
            uint arrayIndex = getRandomArrayIndex(block.timestamp.add(i), CDPOwners.length);
            address currentAddress = CDPOwners[arrayIndex];
            uint currentICR = getCurrentICR(currentAddress, price);

            // check if abs(current - CR) > abs(closest - CR), and update closest if current is closer
            uint currentDiff = getAbsoluteDifference(currentICR, CR);

            if (currentDiff < diff) {
                closestICR = currentICR;
                diff = currentDiff;
                hintAddress = currentAddress;
            }
            i++;
        }
    return hintAddress;
}

    function getAbsoluteDifference(uint a, uint b) internal view returns(uint) {
        if (a >= b) {
            return a.sub(b);
        } else if (a < b) {
            return b.sub(a);
        }
    }

    // Convert input to pseudo-random uint in range [0, arrayLength - 1]
    function getRandomArrayIndex(uint input, uint _arrayLength) internal view returns(uint) {
        uint randomIndex = uint256(keccak256(abi.encodePacked(input))) % (_arrayLength);
        return randomIndex;
   }

    // Return the current collateral ratio (ICR) of a given CDP. Takes pending coll/debt rewards into account.
    function getCurrentICR(address _user, uint _price) public view returns(uint) {
        uint pendingETHReward = computePendingETHReward(_user); 
        uint pendingCLVDebtReward = computePendingCLVDebtReward(_user); 
        
        uint currentETH = CDPs[_user].coll.add(pendingETHReward); 
        uint currentCLVDebt = CDPs[_user].debt.add(pendingCLVDebtReward); 
       
        uint ICR = computeICR(currentETH, currentCLVDebt, _price);  
        return ICR;
    }

    // Compute the new collateral ratio, considering the collateral to be removed. Assumes 0 pending rewards.
    function getNewICRfromCollDecrease(address _user, uint _collDecrease, uint _price) view internal returns(uint) {
        uint newColl = CDPs[_user].coll.sub(_collDecrease);
        
        return computeICR(newColl, CDPs[_user].debt, _price);
    }

    // Compute the new collateral ratio, considering the debt to be added. Assumes 0 pending rewards.
    function getNewICRfromDebtIncrease(address _user, uint _debtIncrease, uint _price) view internal returns(uint) {
        uint newCLVDebt = CDPs[_user].debt.add(_debtIncrease);

        return computeICR(CDPs[_user].coll, newCLVDebt, _price);
    } 

    // Compute the new collateral ratio, considering the change in coll and debt.
    function getNewICRFromTroveAdjustment(address _user, int _collChange, int _debtChange, uint _price) 
    view
    internal 
    returns(uint)
    {
        uint newDebt;
        uint newColl;

        if (_debtChange > 0) {
            newDebt = CDPs[_user].debt.add(intToUint(_debtChange));
        } else if (_debtChange < 0) {
            newDebt = CDPs[_user].debt.sub(intToUint(_debtChange));
        }

        if (_collChange > 0) {
            newColl = CDPs[_user].coll.add(intToUint(_collChange));
        } else if (_collChange < 0) {
            // console.log("_collChange: %s", _collChange);
            console.log("intToUint(_collChange): %s", intToUint(_collChange));
            console.log("CDPs[_user].coll: %s", CDPs[_user].coll);

            newColl = CDPs[_user].coll.sub(intToUint(_collChange));
        }

        return computeICR(newColl, newDebt, _price);
    }

    function computeICR(uint _coll, uint _debt, uint _price) view internal returns(uint) {
        // Check if the total debt is higher than 0, to avoid division by 0
        if (_debt > 0) {

            // Pure division to decimal
            uint newCollRatio = _coll.mul(_price).div(_debt);

            return newCollRatio;
        }
        // Return the maximal value for uint256 if the CDP has a debt of 0
        else {
            return 2**256 - 1; 
        }
    }

    // Add the user's coll and debt rewards earned from liquidations, to their CDP
    function applyPendingRewards(address _user) internal returns(bool) {
        if (hasPendingRewards(_user) == false) { return false; }
        require(CDPs[_user].status == Status.active, "CDPManager: user must have an active CDP"); 

        // Compute pending rewards
        uint pendingETHReward = computePendingETHReward(_user); 
        uint pendingCLVDebtReward = computePendingCLVDebtReward(_user);  

        // Apply pending rewards
        CDPs[_user].coll = CDPs[_user].coll.add(pendingETHReward);  
        CDPs[_user].debt = CDPs[_user].debt.add(pendingCLVDebtReward); 

        // Tell PM to transfer from DefaultPool to ActivePool when user claims rewards
        poolManager.moveDistributionRewardsToActivePool(pendingCLVDebtReward, pendingETHReward); 

        updateRewardSnapshots(_user); // 5259 (no rewards)
        return true;
    }

    // Update user's snapshots of L_ETH and L_CLVDebt to reflect the current values
    function updateRewardSnapshots(address _user) internal returns(bool) {
        rewardSnapshots[_user].ETH = L_ETH; 
        rewardSnapshots[_user].CLVDebt = L_CLVDebt; 
        return true;
    }
    
    // Get the user's pending accumulated ETH reward, earned by its stake
    function computePendingETHReward(address _user) internal view returns(uint) {
        uint snapshotETH = rewardSnapshots[_user].ETH; 
        uint rewardPerUnitStaked = L_ETH.sub(snapshotETH); 
        
        if ( rewardPerUnitStaked == 0 ) { return 0; }
       
        uint stake = CDPs[_user].stake;
        
        uint pendingETHReward = stake.mul(rewardPerUnitStaked).div(1e18);

        return pendingETHReward;
    }

     // Get the user's pending accumulated CLV reward, earned by its stake
    function computePendingCLVDebtReward(address _user) internal view returns(uint) {
        uint snapshotCLVDebt = rewardSnapshots[_user].CLVDebt;  
        uint rewardPerUnitStaked = L_CLVDebt.sub(snapshotCLVDebt); 
       
        if ( rewardPerUnitStaked == 0 ) { return 0; }
       
        uint stake =  CDPs[_user].stake; 
      
        uint pendingCLVDebtReward = stake.mul(rewardPerUnitStaked).div(1e18);
     
        return pendingCLVDebtReward;
    }

    function hasPendingRewards(address _user) public view returns (bool) {
        // A CDP has pending rewards if the current reward sum differs from the CDP's snapshot
        return (rewardSnapshots[_user].ETH != L_ETH);
    }

    /* Computes the CDPs entire debt and coll, including distribution pending rewards. Transfers any rewards 
    from Default Pool to Active Pool. */ 
    function getEntireDebtAndColl(address _user) 
    internal 
    returns (uint debt, uint coll)
    {
        debt = CDPs[_user].debt;
        coll = CDPs[_user].coll;

        if (hasPendingRewards(_user)) {
            uint pendingCLVDebtReward = computePendingCLVDebtReward(_user);
            uint pendingETHReward = computePendingETHReward(_user);

            debt = debt.add(pendingCLVDebtReward);
            coll = coll.add(pendingETHReward);

            poolManager.moveDistributionRewardsToActivePool(pendingCLVDebtReward, pendingETHReward); 
        }

        return (debt, coll);
    }

    // Remove use's stake from the totalStakes sum, and set their stake to 0
    function removeStake(address _user) internal returns (bool) {
        uint stake = CDPs[_user].stake;
        totalStakes = totalStakes.sub(stake);
        CDPs[_user].stake = 0;
    }

    // Update user's stake based on their latest collateral value
    function updateStakeAndTotalStakes(address _user) internal returns(bool) {
        uint newStake = computeNewStake(CDPs[_user].coll); 
        uint oldStake = CDPs[_user].stake;
        CDPs[_user].stake = newStake;
        totalStakes = totalStakes.sub(oldStake).add(newStake);

        return true;
    }

    function computeNewStake(uint _coll) internal view returns (uint) {
        uint stake;
        if (totalCollateralSnapshot == 0) {
            stake = _coll;
        } else {
            stake = _coll.mul(totalStakesSnapshot).div(totalCollateralSnapshot);
        }
     return stake;
    }

    function redistributeDebtAndColl(uint _debt, uint _coll) internal returns (bool) {
        if (_debt == 0) { return false; }
        
        if (totalStakes > 0) {
            // Add distributed coll and debt rewards-per-unit-staked to the running totals.
            
            // Division with correction
            uint ETHNumerator = _coll.mul(1e18).add(lastETHError_Redistribution);
            uint CLVDebtNumerator = _debt.mul(1e18).add(lastCLVDebtError_Redistribution);

            uint ETHRewardPerUnitStaked = ETHNumerator.div(totalStakes);
            uint CLVDebtRewardPerUnitStaked = CLVDebtNumerator.div(totalStakes);

            lastETHError_Redistribution = ETHNumerator.sub(ETHRewardPerUnitStaked.mul(totalStakes));
            lastCLVDebtError_Redistribution = CLVDebtNumerator.sub(CLVDebtRewardPerUnitStaked.mul(totalStakes));

            L_ETH = L_ETH.add(ETHRewardPerUnitStaked);
            L_CLVDebt = L_CLVDebt.add(CLVDebtRewardPerUnitStaked);
        }
        // Transfer coll and debt from ActivePool to DefaultPool
        poolManager.liquidate(_debt, _coll);
    }

    function closeCDP(address _user) internal returns (bool) {
        CDPs[_user].status = Status.closed;
        CDPs[_user].coll = 0;
        CDPs[_user].debt = 0;
        
        rewardSnapshots[_user].ETH = 0;
        rewardSnapshots[_user].CLVDebt = 0;
        
        sortedCDPs.remove(_user);
        removeCDPOwner(_user);
       
        return true;
    }

    // Update the snapshots of system stakes & system collateral
    function updateSystemSnapshots() internal returns (bool) {
        totalStakesSnapshot = totalStakes;

        /* The total collateral snapshot is the sum of all active collateral and all pending rewards
       (ActivePool ETH + DefaultPool ETH), immediately after the liquidation occurs. */
        uint activeColl = activePool.getETH();
        uint liquidatedColl = defaultPool.getETH();
        totalCollateralSnapshot = activeColl.add(liquidatedColl);

        return true;
    }

    // Updates snapshots of system stakes and system collateral, excluding a given collateral remainder from the calculation
     function updateSystemSnapshots_excludeCollRemainder(uint _collRemainder) internal returns (bool) {
        totalStakesSnapshot = totalStakes;

        uint activeColl = activePool.getETH();
        uint liquidatedColl = defaultPool.getETH();
        totalCollateralSnapshot = activeColl.sub(_collRemainder).add(liquidatedColl);

        return true;
    }
  
     /* Remove a CDP owner from the CDPOwners array, preserving array length but not order. Deleting owner 'B' does the following: 
    [A B C D E] => [A E C D], and updates E's CDP struct to point to its new array index. */
    function removeCDPOwner(address _user) internal returns(bool) {
        require(CDPs[_user].status == Status.closed, "CDPManager: CDP is still active");

        uint index = CDPs[_user].arrayIndex;   
        address addressToMove = CDPOwners[CDPOwners.length - 1];
       
        CDPOwners[index] = addressToMove;   
        CDPs[addressToMove].arrayIndex = index;   
        CDPOwners.length--;  
    }

    // Get the dollar value of collateral, as a duint
    function getUSDValue(uint _coll, uint _price) public view returns (uint) {
        uint usdValue = _price.mul(_coll).div(1e18);

        return usdValue;
    }

    function getNewTCR(uint _collIncrease, uint _debtIncrease, uint _price) internal view returns (uint) {
        uint activeColl = activePool.getETH();
        uint activeDebt = activePool.getCLV();
        uint liquidatedColl = defaultPool.getETH();
        uint closedDebt = defaultPool.getCLV();

        uint totalCollateral = activeColl.add(liquidatedColl).add(_collIncrease);
        uint newTotalDebt = activeDebt.add(closedDebt).add(_debtIncrease);

        uint newTCR = computeICR(totalCollateral, newTotalDebt, _price);
        return newTCR;
    }

    function getNewTCRFromDecrease(uint _collDecrease, uint _debtDecrease, uint _price) internal view returns (uint) {
        uint activeColl = activePool.getETH();
        uint activeDebt = activePool.getCLV();
        uint liquidatedColl = defaultPool.getETH();
        uint closedDebt = defaultPool.getCLV();

        uint totalCollateral = activeColl.add(liquidatedColl).sub(_collDecrease);
        uint newTotalDebt = activeDebt.add(closedDebt).sub(_debtDecrease);

        uint newTCR = computeICR(totalCollateral, newTotalDebt, _price);
        return newTCR;
    }

    function getNewTCRFromTroveAdjustment(int _collChange, int _debtChange, uint _price) internal view returns (uint) {
        uint currentTotalColl = activePool.getETH().add(defaultPool.getETH());
        uint currentTotalDebt = activePool.getCLV().add(defaultPool.getCLV());
       
        uint newTotalDebt;
        uint newTotalCollateral;
        
        if (_debtChange > 0) {
            newTotalDebt = currentTotalDebt.add(intToUint(_debtChange));
        } else if (_debtChange < 0) {
            newTotalDebt = currentTotalDebt.sub(intToUint(_debtChange));
        }

        if (_collChange > 0) {
            newTotalCollateral = currentTotalColl.add(intToUint(_collChange));
        } else if (_collChange < 0) {
            newTotalCollateral = currentTotalColl.sub(intToUint(_collChange));
        }

        uint newTCR = computeICR(newTotalCollateral, newTotalDebt, _price);
        return newTCR;
    }

    function checkRecoveryMode() public view returns (bool){
        uint price = priceFeed.getPrice();

        uint activeColl = activePool.getETH();
        uint activeDebt = activePool.getCLV();
        uint liquidatedColl = defaultPool.getETH();
        uint closedDebt = defaultPool.getCLV();

        uint totalCollateral = activeColl.add(liquidatedColl);
        uint totalDebt = activeDebt.add(closedDebt); 

        uint TCR = computeICR(totalCollateral, totalDebt, price); 
        
        if (TCR < CCR) {
            return true;
        } else {
            return false;
        }
    }

    /* Converts the magnitude of an int to a uint
    TODO:  check validity for num in region (num > 2**255) or (num < -2**255) */
    function intToUint(int num) internal pure returns (uint) {
        if (num < 0) {
            return uint(-num);
        } else {
            return uint(num);
        }
    }

    function requireCDPisActive(address _user) internal view {
        require(CDPs[_user].status == Status.active, "CDPManager: CDP does not exist or is closed");
    }
    function requireNotInRecoveryMode() internal view {
        require(checkRecoveryMode() == false, "CDPManager: Operation not permitted during Recovery Mode");
    }

    function requireICRisAboveMCR(uint _newICR)  internal view {
        require(_newICR >= MCR, "CDPManager: An operation that would result in ICR < MCR is not permitted");
    }

    function requireTCRisAboveCCR(uint _newTCR) internal view {
        require(_newTCR >= CCR, "CDPManager: An operation that would result in TCR < CCR is not permitted");
    }

    function requireCLVRepaymentAllowed(uint _currentDebt, uint _debtDecrease) internal pure {
        require(_debtDecrease > 0, "CDPManager: Repaid amount must be larger than 0");
        require(_debtDecrease <= _currentDebt, "CDPManager: Amount repaid must not be larger than the CDP's debt");
    }

    function requireValueIsGreaterThan20Dollars(uint _amount, uint _price) internal view {
         require(getUSDValue(_amount, _price) >= MIN_COLL_IN_USD,  
            "CDPManager: Collateral must have $USD value >= 20");
    }

    function requireNonZeroAmount(uint _amount) internal pure {
        require(_amount > 0, "CDPManager: Amount must be larger than 0");
    }

    function requireCollAmountIsWithdrawable(uint _currentColl, uint _collWithdrawal, uint _price) 
    internal 
    view 
    {
        require(_collWithdrawal <= _currentColl, "CDPManager: Insufficient balance for ETH withdrawal");
        
        uint newColl = _currentColl.sub(_collWithdrawal);
        require(getUSDValue(newColl, _price) >= MIN_COLL_IN_USD || newColl == 0,
            "CDPManager: Remaining collateral must have $USD value >= 20, or be zero");
    }
}