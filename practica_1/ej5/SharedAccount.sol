// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
["0x5B38Da6a701c568545dCfcB03FcB875f56beddC4","0xAb8483F64d9C6d1EcF9b849Ae677dD3315835cb2", "0x4B20993Bc481177ec7E8f571ceCaE8A9e22C02db", "0x78731D3Ca6b7E34aC0F824c42a7cC18A495cabaB", "0x617F2E2fD72FD9D5503197092aC168c91465E7f2"]
 * Tesorería compartida para una asociación estudiantil.
 *
 * Cambios principales respecto al borrador recibido:
 * - Los cinco miembros y el umbral de tres aprobaciones quedan fijados en el despliegue.
 * - Se elimina la comisión por aprobar: votar no debe exigir un pago adicional.
 * - Cada propuesta incluye destinatario, importe, descripción y fecha límite.
 * - Cualquier miembro puede ejecutar una propuesta aprobada.
 * - El estado se cambia antes de transferir Ether para impedir pagos repetidos por reentrada.
 */
contract SharedAccount {
    // Fijar estos valores evita que el grupo o el quórum cambien después de aprobar gastos.
    uint256 public constant MEMBER_COUNT = 5;
    uint256 public constant REQUIRED_APPROVALS = 3;

    // La propuesta conserva sus datos originales; solo cambian el recuento de votos y el estado.
    enum ProposalStatus {
        Pending,
        Executed
    }

    struct Proposal {
        address payable recipient;
        uint256 amount;
        string description;
        uint256 expiresAt;
        uint8 approvalCount;
        ProposalStatus status;
    }

    // Se guardan las cinco direcciones y una búsqueda directa para validar miembros sin recorrer la lista.
    address[MEMBER_COUNT] public members;
    mapping(address => bool) public isMember;

    // El contador asigna IDs desde cero; las propuestas quedan accesibles mediante su ID.
    uint256 public proposalCount;
    mapping(uint256 => Proposal) public proposals;

    // Registra el voto actual de cada miembro en cada propuesta y evita votos duplicados.
    mapping(uint256 => mapping(address => bool)) public hasApproved;

    // Bloquea ejecuciones anidadas mientras se llama al destinatario del pago.
    bool private paymentInProgress;

    event FundsDeposited(address indexed member, uint256 amount);
    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        address indexed recipient,
        uint256 amount,
        string description,
        uint256 expiresAt
    );
    event ProposalApproved(uint256 indexed proposalId, address indexed member);
    event ApprovalRevoked(uint256 indexed proposalId, address indexed member);
    event ProposalExecuted(
        uint256 indexed proposalId,
        address indexed executor,
        address indexed recipient,
        uint256 amount
    );

    error NotMember();
    error DuplicatedMember();
    error InvalidID();
    error PaymentInProgress();
    error InvalidAddress();
    error InsufficientAmount();
    error EmptyDescription();
    error ExpiredProposal();
    error InvalidStatus();
    error NotApproved();
    error DuplicateApproval();
    error InsufficientApprovals();
    error InsufficientBalance();
    error InvalidPayment();

    // Restringe las acciones de gobierno a las cinco direcciones definidas al desplegar.
    modifier onlyMember() {
        if(!isMember[msg.sender]) revert NotMember();
        _;
    }

    // Impide consultar o modificar IDs que todavía no corresponden a una propuesta.
    modifier proposalExists(uint256 _proposalId) {
        if(_proposalId >= proposalCount) revert InvalidID();
        _;
    }

    // Defensa global: un destinatario no puede iniciar otra ejecución durante una transferencia.
    modifier nonReentrantPayment() {
        if(paymentInProgress) revert PaymentInProgress();
        paymentInProgress = true;
        _;
        paymentInProgress = false;
    }

    /**
     * Recibe exactamente cinco miembros distintos y no nulos.
     * Se configura una sola vez para que las propuestas no cambien de grupo a mitad de votación.
     */
    constructor(address[MEMBER_COUNT] memory _members) {
        for (uint256 i = 0; i < MEMBER_COUNT; i++) {
            address member = _members[i];
            if(member == address(0)) revert InvalidAddress();
            if(isMember[member]) revert DuplicatedMember();

            members[i] = member;
            isMember[member] = true;
        }
    }

    /**
     * Permite a un miembro aportar ETH a la tesorería.
     * No se exige una cuota mínima para que cualquier aportación positiva sea válida.
     */
    function deposit() external payable onlyMember {
        if(msg.value == 0) revert InsufficientAmount();
        emit FundsDeposited(msg.sender, msg.value);
    }

    /**
     * Consulta el saldo común en wei.
     * La dirección del contrato y su saldo también pueden verificarse públicamente en la blockchain.
     */
    function treasuryBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /**
     * Crea una propuesta inmutable sobre destinatario, importe, motivo y vencimiento.
     * No se exige que haya saldo suficiente ahora: el saldo se comprueba al ejecutar el pago,
     * ya que los miembros pueden depositar fondos mientras la propuesta está pendiente.
     */
    function createProposal(
        address payable _recipient,
        uint256 _amount,
        string calldata _description,
        uint256 _expiresAt
    ) external onlyMember returns (uint256 proposalId) {
        if(_recipient == address(0)) revert InvalidAddress();
        if(_amount == 0) revert InsufficientAmount();
        if(bytes(_description).length == 0) revert EmptyDescription();
        if(_expiresAt <= block.timestamp) revert ExpiredProposal();

        proposalId = proposalCount;
        proposalCount++;

        proposals[proposalId] = Proposal({
            recipient: _recipient,
            amount: _amount,
            description: _description,
            expiresAt: _expiresAt,
            approvalCount: 0,
            status: ProposalStatus.Pending
        });

        emit ProposalCreated(
            proposalId,
            msg.sender,
            _recipient,
            _amount,
            _description,
            _expiresAt
        );
    }

    /**
     * Añade el voto del miembro actual si la propuesta sigue pendiente y vigente.
     * La función no es payable: una aprobación es una decisión, no una compra ni una aportación.
     */
    function approveProposal(uint256 _proposalId)
        external
        onlyMember
        proposalExists(_proposalId)
    {
        Proposal storage proposal = proposals[_proposalId];
        if(proposal.status != ProposalStatus.Pending) revert InvalidStatus();
        if(block.timestamp >= proposal.expiresAt) revert ExpiredProposal();
        if(hasApproved[_proposalId][msg.sender]) revert DuplicateApproval();

        hasApproved[_proposalId][msg.sender] = true;
        proposal.approvalCount++;

        emit ProposalApproved(_proposalId, msg.sender);
    }

    /**
     * Permite retirar un voto antes de la ejecución.
     * El recuento se reduce junto con el voto para que la propuesta vuelva a necesitar el quórum.
     */
    function revokeApproval(uint256 _proposalId)
        external
        onlyMember
        proposalExists(_proposalId)
    {
        Proposal storage proposal = proposals[_proposalId];
        if(proposal.status != ProposalStatus.Pending) revert InvalidStatus();
        if(!hasApproved[_proposalId][msg.sender]) revert NotApproved();

        hasApproved[_proposalId][msg.sender] = false;
        proposal.approvalCount--;

        emit ApprovalRevoked(_proposalId, msg.sender);
    }

    /**
     * Cualquier miembro puede ejecutar el pago cuando hay tres votos, la propuesta sigue vigente
     * y existe saldo suficiente; no hace falta que la ejecute quien la creó.
     */
    function executeProposal(uint256 _proposalId)
        external
        onlyMember
        proposalExists(_proposalId)
        nonReentrantPayment
    {
        Proposal storage proposal = proposals[_proposalId];
        if(proposal.status != ProposalStatus.Pending) revert InvalidStatus();
        if(block.timestamp >= proposal.expiresAt) revert ExpiredProposal();
        if(proposal.approvalCount < REQUIRED_APPROVALS) revert InsufficientApprovals();
        if(address(this).balance < proposal.amount) revert InsufficientBalance();

        // Se marca ejecutada antes de llamar a una dirección externa, evitando pagar dos veces
        // la misma propuesta si el destinatario intenta volver a entrar en el contrato.
        proposal.status = ProposalStatus.Executed;

        // call permite enviar ETH y devuelve el resultado; si falla, revertir restaura el estado anterior.
        (bool success, ) = proposal.recipient.call{value: proposal.amount}("");
        if(!success) revert InvalidPayment();

        emit ProposalExecuted(_proposalId, msg.sender, proposal.recipient, proposal.amount);
    }

    /**
     * La caducidad depende del tiempo y no necesita una transacción para actualizarse.
     * Esta consulta permite a la interfaz distinguir una propuesta pendiente de una vencida.
     */
    function isProposalExpired(uint256 _proposalId)
        external
        view
        proposalExists(_proposalId)
        returns (bool)
    {
        return block.timestamp >= proposals[_proposalId].expiresAt;
    }
}
