/*

    Copyright 2020 DODO ZOO.
    SPDX-License-Identifier: Apache-2.0

*/

pragma solidity 0.6.9;

import {IDODOApproveProxy} from "../DODOApproveProxy.sol";
import {ICloneFactory} from "../../lib/CloneFactory.sol";
import {IERC20} from "../../intf/IERC20.sol";
import {IWETH} from "../../intf/IWETH.sol";
import {InitializableOwnable} from "../../lib/InitializableOwnable.sol";
import {ICollateralVault} from "../../CollateralVault/intf/ICollateralVault.sol";
import {IDVM} from "../../DODOVendingMachine/intf/IDVM.sol";
import {IFragment} from "../../GeneralizedFragment/intf/IFragment.sol";
import {IDODONFTRegistry} from "../../Factory/Registries/DODONFTRegistry.sol";
import {SafeMath} from "../../lib/SafeMath.sol";
import {SafeERC20} from "../../lib/SafeERC20.sol";
import {DecimalMath} from "../../lib/DecimalMath.sol";
import {ReentrancyGuard} from "../../lib/ReentrancyGuard.sol";


/**
 * @title DODONFTProxy
 * @author DODO Breeder
 *
 * @notice Entrance of NFT in DODO platform
 */
contract DODONFTProxy is ReentrancyGuard, InitializableOwnable {
    using SafeMath for uint256;


    // ============ Storage ============

    address constant _ETH_ADDRESS_ = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address public immutable _WETH_;
    address public immutable _DODO_APPROVE_PROXY_;
    address public immutable _CLONE_FACTORY_;
    address public immutable _NFT_REGISTY_;
    address public immutable _DEFAULT_MAINTAINER_;
    
    address public _MT_FEE_RATE_MODEL_;
    address public _VAULT_TEMPLATE_;
    address public _FRAG_TEMPLATE_;
    address public _DVM_TEMPLATE_;

    uint256 public _DEFAULT_BUYOUT_FEE_;

    // ============ Events ============
    event ChangeVaultTemplate(address newVaultTemplate);
    event ChangeFragTemplate(address newFragTemplate);
    event ChangeDvmTemplate(address newDvmTemplate);
    event ChangeMtFeeRateTemplate(address newMtFeeRateTemplate);
    event ChangeBuyoutFee(uint256 newBuyoutFee);
    event CreateNFTCollateralVault(address creator, address vault, string name, string baseURI);
    event CreateFragment(address vault, address fragment, address dvm);
    event Buyout(address from, address fragment, uint256 amount);

    // ============ Modifiers ============

    modifier judgeExpired(uint256 deadLine) {
        require(deadLine >= block.timestamp, "DODONFTProxy: EXPIRED");
        _;
    }

    fallback() external payable {}

    receive() external payable {}

    constructor(
        address cloneFactory,
        address payable weth,
        address dodoApproveProxy,
        address defaultMaintainer,
        address mtFeeRateModel,
        address vaultTemplate,
        address fragTemplate,
        address dvmTemplate,
        address nftRegistry
    ) public {
        _CLONE_FACTORY_ = cloneFactory;
        _WETH_ = weth;
        _DODO_APPROVE_PROXY_ = dodoApproveProxy;
        _DEFAULT_MAINTAINER_ = defaultMaintainer;
        _MT_FEE_RATE_MODEL_ = mtFeeRateModel;
        _VAULT_TEMPLATE_ = vaultTemplate;
        _FRAG_TEMPLATE_ = fragTemplate;
        _DVM_TEMPLATE_ = dvmTemplate;
        _NFT_REGISTY_ = nftRegistry;
    }

    function createNFTCollateralVault(string memory name, string memory baseURI) external returns (address newVault) {
        newVault = ICloneFactory(_CLONE_FACTORY_).clone(_VAULT_TEMPLATE_);
        ICollateralVault(newVault).init(msg.sender, name, baseURI);
        emit CreateNFTCollateralVault(msg.sender, newVault, name, baseURI);
    }
    
    function createFragment(
        address quoteToken,
        address vaultPreOwner,
        uint256[] calldata dvmParams, //0 - lpFeeRate, 1 - I, 2 - K
        uint256[] calldata fragParams, //0 - totalSupply, 1 - ownerRatio, 2 - buyoutTimestamp
        bool isOpenTwap 
    ) external returns (address newFragment, address newDvm) {
        newFragment = ICloneFactory(_CLONE_FACTORY_).clone(_FRAG_TEMPLATE_);
        address _quoteToken = quoteToken == _ETH_ADDRESS_ ? _WETH_ : quoteToken;
        
        {
        uint256[] memory  _dvmParams = dvmParams;
        uint256[] memory  _fragParams = fragParams;
        
        newDvm = ICloneFactory(_CLONE_FACTORY_).clone(_DVM_TEMPLATE_);
        IDVM(newDvm).init(
            _DEFAULT_MAINTAINER_,
            newFragment,
            _quoteToken,
            _dvmParams[0],
            _MT_FEE_RATE_MODEL_,
            _dvmParams[1],
            _dvmParams[2],
            isOpenTwap
        );
        IFragment(newFragment).init(
            newDvm, 
            vaultPreOwner, 
            msg.sender, 
            _fragParams[0], 
            _fragParams[1], 
            _fragParams[2],
            _DEFAULT_MAINTAINER_,
            _DEFAULT_BUYOUT_FEE_
        );
        }

        ICollateralVault(msg.sender).directTransferOwnership(newFragment);
        
        IDODONFTRegistry(_NFT_REGISTY_).addRegistry(msg.sender, newFragment, _quoteToken, newDvm);

        emit CreateFragment(msg.sender, newFragment, newDvm);
    }

    function buyout(
        address fragment,
        uint256 quoteMaxAmount,
        uint8 flag, // 0 - ERC20, 1 - quoteInETH
        uint256 deadLine
    ) external payable preventReentrant judgeExpired(deadLine) {
        if(flag == 0)
            require(msg.value == 0, "DODONFTProxy: WE_SAVED_YOUR_MONEY");
        
        address dvm = IFragment(fragment)._DVM_();
        uint256 fragTotalSupply = IFragment(fragment).totalSupply();
        uint256 buyPrice = IDVM(dvm).getMidPrice();

        uint256 curRequireQuote = DecimalMath.mulCeil(buyPrice, fragTotalSupply);

        require(curRequireQuote <= quoteMaxAmount, "DODONFTProxy: CURRENT_TOTAL_VAULE_MORE_THAN_QUOTEMAX");

        _deposit(msg.sender, fragment, IFragment(fragment)._QUOTE_(), curRequireQuote, flag == 1);
        IFragment(fragment).buyout(msg.sender);

        IDODONFTRegistry(_NFT_REGISTY_).removeRegistry(fragment);

        // refund dust eth
        if (flag == 1 && msg.value > curRequireQuote) msg.sender.transfer(msg.value - curRequireQuote);

        emit Buyout(msg.sender, fragment, curRequireQuote);
    }

    //============= Owner ===================
    function updateVaultTemplate(address newVaultTemplate) external onlyOwner {
        _VAULT_TEMPLATE_ = newVaultTemplate;
        emit ChangeVaultTemplate(newVaultTemplate);
    }

    function updateFragTemplate(address newFragTemplate) external onlyOwner {
        _FRAG_TEMPLATE_ = newFragTemplate;
        emit ChangeFragTemplate(newFragTemplate);
    }

    function updateMtFeeRateTemplate(address newMtFeeRateTemplate) external onlyOwner {
        _MT_FEE_RATE_MODEL_ = newMtFeeRateTemplate;
        emit ChangeMtFeeRateTemplate(newMtFeeRateTemplate);
    }

    function updateDvmTemplate(address newDvmTemplate) external onlyOwner {
        _DVM_TEMPLATE_ = newDvmTemplate;
        emit ChangeDvmTemplate(newDvmTemplate);
    }

    function updateBuyoutFee(uint256 buyoutFee) external onlyOwner {
        _DEFAULT_BUYOUT_FEE_ = buyoutFee;
        emit ChangeBuyoutFee(buyoutFee);
    }


    //============= Internal ================

    function _deposit(
        address from,
        address to,
        address token,
        uint256 amount,
        bool isETH
    ) internal {
        if (isETH) {
            if (amount > 0) {
                IWETH(_WETH_).deposit{value: amount}();
                if (to != address(this)) SafeERC20.safeTransfer(IERC20(_WETH_), to, amount);
            }
        } else {
            IDODOApproveProxy(_DODO_APPROVE_PROXY_).claimTokens(token, from, to, amount);
        }
    }
}
