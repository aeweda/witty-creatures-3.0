// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
// import "@openzeppelin/contracts/utils/Strings.sol";

import "./interfaces/IWc3Admin.sol";
import "./interfaces/IWc3Events.sol";
import "./interfaces/IWc3Surrogates.sol";
import "./interfaces/IWc3View.sol";

/// @title Witty Creatures 3.0 - ERC721 Token contract
/// @author Otherplane Labs, 2022.
contract Wc3Token
    is
        ERC721,
        Ownable,
        ReentrancyGuard,
        IWc3Admin,
        IWc3Events,
        IWc3Surrogates,
        IWc3View
{
    // using Strings for bytes32;
    using Strings for uint256;
    using Wc3Lib for bytes32;
    using Wc3Lib for string;
    using Wc3Lib for Wc3Lib.Storage;

    IWitnetRandomness immutable public override randomizer;
    IWitnetPriceRouter immutable public override router;

    uint256 immutable public guildId;
    bytes32 immutable public usdPriceAssetId;
    bytes32 immutable internal __version;

    Wc3Lib.Storage internal __storage;    

    modifier inStatus(Wc3Lib.Status _status) {
        require(
            __storage.status(randomizer) == _status,
            Wc3Lib.statusRevertMessage(_status)
        );
        _;
    }

    modifier tokenExists(uint256 _tokenId) {
        require(
            _exists(_tokenId),
            "Wc3Token: inexistent token"
        );
        _;
    }

    constructor(
            string memory _version,
            address _randomizer,
            address _router,
            address _decorator,
            address _signator,
            uint8[] memory _percentileMarks,
            uint256 _expirationBlocks,
            uint256 _totalEggs,
            string memory _currencySymbol,
            uint256 _mintGasLimit            
        )
        ERC721("Witty Creatures EthCC'5", "WC3")
    {
        assert(_randomizer != address(0));
        assert(_router != address(0));

        guildId = block.chainid;        
        __version = _version.toBytes32();      

        randomizer = IWitnetRandomness(_randomizer);
        router = IWitnetPriceRouter(_router);

        setDecorator(
            IWc3Decorator(_decorator)
        );
        setMintGasLimit(
            _mintGasLimit
        );
        setSettings(
            _expirationBlocks,
            _totalEggs,
            _percentileMarks
        );
        setSignator(
            _signator
        );        

        string memory _usdPriceCaption = string(abi.encodePacked(
           "Price-",
           _currencySymbol,
           "/USD-6" 
        ));
        require(
            router.supportsCurrencyPair(keccak256(bytes(_usdPriceCaption))),
            string(abi.encodePacked(
                bytes("Wc3Token: unsupported currency pair: "),
                _usdPriceCaption
            ))
        );
        usdPriceAssetId = keccak256(bytes(_usdPriceCaption));
    }

    /// @dev Required for receiving unused funds back when calling to `randomizer.randomize()`
    receive() external payable {}


    // ========================================================================
    // --- 'ERC721Metadata' overriden functions -------------------------------
  
    function baseURI()
        public view
        virtual
        returns (string memory)
    {
        return decorator().baseURI();
    }
    
    function metadata(uint256 _tokenId)
        external view 
        virtual 
        tokenExists(_tokenId)
        returns (string memory)
    {
        return decorator().toJSON(
            randomizer.getRandomnessAfter(__storage.hatchingBlock),
            __storage.intrinsics[_tokenId]
        );
    }

    function tokenURI(uint256 _tokenId)
        public view
        virtual override
        tokenExists(_tokenId)
        returns (string memory)
    {
        return string(abi.encodePacked(
            baseURI(),
            "metadata/",
            _tokenId.toString()
        ));
    }


    // ========================================================================
    // --- Implementation of 'IWc3Admin' --------------------------------------

    /// Sets Opensea-compliant Decorator contract
    /// @dev Only callable by the owner, when in 'Batching' status.
    function setDecorator(IWc3Decorator _decorator)
        public
        override
        onlyOwner
        inStatus(Wc3Lib.Status.Batching)
    {
        require(
            address(_decorator) != address(0),
            "Wc3Token: no decorator"
        );
        __storage.decorator = address(_decorator);
        emit Decorator(address(_decorator));
    }

    /// Set estimated gas units required for minting one single token.
    /// @dev Only callable by the owner, at any time.
    /// @param _estimatedGasLimit Estimated gas units.
    function setMintGasLimit(
            uint256 _estimatedGasLimit
        )
        public override
        onlyOwner
    {
        __storage.mintGasLimit = _estimatedGasLimit;
        emit MintGasLimit(_estimatedGasLimit);
    }

    /// Sets Externally Owned Account that is authorized to sign tokens' intrinsics before getting minted.
    /// @dev Only callable by the owner, at any time.
    /// @dev Cannot be set to zero address.
    /// @param _signator Externally-owned account to be authorized    
    function setSignator(address _signator)
        public override
        onlyOwner
    {
        require(
            _signator != address(0),
            "Wc3Token: no signator"
        );
        __storage.signator = _signator;
        emit Signator(_signator);
    }

    /// Change batch parameters. Only possible while in 'Batching' status.
    /// @dev Only callable by the owner, while on 'Batching' status.
    /// @param _expirationBlocks Number of blocks after Witnet randomness is generated, during which creatures may get minted.
    /// @param _totalEggs Max number of tokens that may eventually get minted.
    /// @param _percentileMarks Creature-category ordered percentile marks (Legendary first).   
    function setSettings(
            uint256 _expirationBlocks,
            uint256 _totalEggs,
            uint8[] memory _percentileMarks
        )
        public
        virtual override
        onlyOwner
        inStatus(Wc3Lib.Status.Batching)
    {
        require(
            _totalEggs > 0,
            "Wc3Token: zero eggs"
        );
        require(
            _percentileMarks.length == uint8(Wc3Lib.WittyCreatureRarity.Common) + 1,
            "Wc3Token: bad percentile marks"
        );        

        __storage.settings.expirationBlocks = _expirationBlocks;
        __storage.settings.totalEggs = _totalEggs;
        __storage.settings.percentileMarks = new uint8[](_percentileMarks.length);

        uint8 _checkSum; for (uint8 _i = 0; _i < _percentileMarks.length; _i ++) {
            uint8 _mark = _percentileMarks[_i];
            __storage.settings.percentileMarks[_i] = _mark;
            _checkSum += _mark;
        }
        require(_checkSum == 100, "Wc3Token: bad percentile checksum");

        emit Settings(
            _expirationBlocks,
            _totalEggs,
            _percentileMarks
        );
    }

    /// Starts hatching, which means: (a) game settings cannot be altered anymore, (b) a 
    /// random number will be requested to the Witnet Decentralized Oracle Network, and (c)
    /// the contract will automatically turn to the 'Hatching' status as soon as the randomness
    /// gets solved by the Witnet oracle. While the randomness request gets solved, the contract will 
    /// remain in 'Randomizing' status.
    /// @dev Only callable by the owner, while in 'Batching' status.
    function startHatching()
        external payable
        virtual
        nonReentrant
        onlyOwner
        inStatus(Wc3Lib.Status.Batching)
    {   
        // Decorator must be forged first:
        require(
            decorator().forged(),
            "Wc3Token: unforged decorator"
        );

        // Request randomness from the Witnet oracle:
        uint _usedFunds = randomizer.randomize{ value: msg.value }();

        // Sets hatching block number:
        __storage.hatchingBlock = block.number;
        
        // Transfer back unused funds:
        if (_usedFunds < msg.value ) {
            payable(msg.sender).transfer(msg.value - _usedFunds);   
        }
    }

    // ========================================================================
    // --- Implementation of 'IWc3Surrogates' -------------------------------

    function mint(
            address _tokenOwner,
            string calldata _name,
            uint256 _globalRanking,
            uint256 _guildId,
            uint256 _guildPlayers,
            uint256 _guildRanking,
            uint256 _index,
            uint256 _score,
            bytes calldata _signature
        )
        external
        virtual override
        nonReentrant
        inStatus(Wc3Lib.Status.Hatching)
    {
        // Verify guildfundamental facts:
        _verifyGuildFacts(
            _guildId,
            _guildPlayers,
            _guildRanking
        );

        // Verify signature:
        _verifySignature(
            _tokenOwner,
            _name,
            _globalRanking,
            _guildId,
            _guildPlayers,
            _guildRanking,
            _index,
            _score,            
            _signature
        );

        // Token id will be the same as the achieved guild ranking for this egg during EthCC'5:
        uint256 _tokenId = _guildRanking;

        // Verify the token has not been already minted:
        require(
            __storage.intrinsics[_tokenId].birthTimestamp == 0,
            "Wc3Token: already minted"
        );

        // Save token intrinsics to storage:
        __mintWittyCreature(
            _name,
            _globalRanking,
            _guildPlayers,
            _guildRanking,
            _index,
            _score
        );

        // Mint the actual ERC-721 token:
        _safeMint(_tokenOwner, _tokenId);

        // Increment token supply:
        __storage.totalSupply ++;
    }


    // ========================================================================
    // --- Implementation of 'IWc3View' ------------------------------------

    
    function decorator()
        public view
        override
        returns (IWc3Decorator)
    {
        return IWc3Decorator(__storage.decorator);
    }
    
    function estimateMintUsdCost6(uint _gasPrice)
        public view
        override
        returns (uint64)
    {
        (int _lastKnownPrice,,) = router.valueFor(usdPriceAssetId);
        uint _estimatedFee = _gasPrice * __storage.mintGasLimit;
        return uint64((_estimatedFee * uint(_lastKnownPrice)) / 10 ** 18);
    }

    function getHatchingBlock()
        external view
        override
        returns (uint256)
    {
        return __storage.hatchingBlock;
    }

    function getSettings()
        external view
        override
        returns (Wc3Lib.Settings memory)
    {
        return __storage.settings;
    }

    function getStatus()
        public view
        override
        returns (Wc3Lib.Status)
    {
        return __storage.status(randomizer);
    }

    function getTokenIntrinsics(uint256 _tokenId)
        external view
        override
        returns (Wc3Lib.WittyCreature memory)
    {
        return __storage.intrinsics[_tokenId];
    }

    function getTokenStatus(uint256 _tokenId)
        external view
        override
        returns (Wc3Lib.WittyCreatureStatus)
    {
        return __storage.tokenStatus(randomizer, _tokenId);
    }

    function preview(
            string calldata _name,
            uint256 _globalRanking,
            uint256 _guildId,
            uint256 _guildPlayers,
            uint256 _guildRanking,
            uint256 _index,
            uint256 _score
        )
        external view
        virtual override
        inStatus(Wc3Lib.Status.Hatching)
        returns (string memory)
    {
        // Verify guild facts:
        _verifyGuildFacts(
            _guildId,
            _guildPlayers,
            _guildRanking
        );

        // Preview creature image:
        return decorator().toJSON(
            randomizer.getRandomnessAfter(__storage.hatchingBlock),
            Wc3Lib.WittyCreature({
                name: _name,
                birthTimestamp: 0,
                mintUsdCost6: estimateMintUsdCost6(tx.gasprice),
                globalRanking: _globalRanking,
                guildRanking: _guildRanking,
                index: _index,
                rarity: __storage.rarity((_guildRanking * 100) / _guildPlayers),
                score: _score
            })
        );
    }

    function signator()
        external view
        override
        returns (address)
    {
        return __storage.signator;
    }

    function totalSupply()
        public view
        override
        returns (uint256)
    {
        return __storage.totalSupply;
    }

    function version()
        external view
        override
        returns (string memory)
    {
        return __version.toString();
    }

    
    // ------------------------------------------------------------------------
    // --- INTERNAL VIRTUAL METHODS -------------------------------------------
    // ------------------------------------------------------------------------

    function __mintWittyCreature(
            string calldata _name,
            uint256 _globalRanking,
            uint256 _guildPlayers,
            uint256 _guildRanking,
            uint256 _index,
            uint256 _score
        )
        internal
        virtual
    {
        __storage.intrinsics[_guildRanking] = Wc3Lib.WittyCreature({
            name: _name,
            birthTimestamp: block.timestamp,
            mintUsdCost6: estimateMintUsdCost6(tx.gasprice),
            globalRanking: _globalRanking,
            guildRanking: _guildRanking,
            index: _index,
            rarity: __storage.rarity((_guildRanking * 100) / _guildPlayers),
            score: _score
        });
    }

    function _verifyGuildFacts(
            uint _guildId,
            uint _guildPlayers,
            uint _guildRanking
        )
        internal view
        virtual
    {
        require(_guildId == guildId, "Wc3Token: bad guild");
        
        require(_guildPlayers > 0, "Wc3Token: no players");
        require(_guildPlayers <= __storage.settings.totalEggs, "Wc3Token: bad players");
        
        require(_guildRanking > 0, "Wc3Token: no ranking");
        require(_guildRanking <= _guildPlayers, "Wc3Token: bad ranking");
    }

    function _verifySignature(
            address _tokenOwner,
            string memory _name,
            uint256 _globalRanking,
            uint256 _guildId,
            uint256 _guildPlayers,
            uint256 _guildRanking,
            uint256 _index,
            uint256 _score,
            bytes memory _signature
        )
        internal view
        virtual
    {
        bytes32 _hash = keccak256(abi.encode(
            _tokenOwner,
            _name,
            _globalRanking,
            _guildId,
            _guildPlayers,
            _guildRanking,
            _index,
            _score
        ));
        require(
            Wc3Lib.recoverAddr(_hash, _signature) == __storage.signator,
            "Wc3Token: bad signature"
        );
    }

}
