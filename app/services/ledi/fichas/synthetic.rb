# Ficha sintética (spec §6.1/§6.2): Ficha de Procedimentos com uma aferição de
# PA de um cidadão fictício (CPF de teste com dígito válido). Serve à prova
# técnica, às specs e à semente de dev; NUNCA existe fora de development/test.
module Ledi
  module Fichas
    class Synthetic
      class NotAllowed < StandardError; end

      PROCEDURE = "0301100039"          # SIGTAP 03.01.10.003-9 aferição de pressão arterial
      CITIZEN_CPF = "12345678909"
      CITIZEN_BIRTH = Date.new(1980, 5, 10)
      ORIGIN_THIRD_PARTY = 3            # tpCdsOrigem: sistema de terceiro

      attr_reader :cnes, :ine, :professional_cns, :cbo, :attended_at, :source_id

      def initialize(cnes:, ine:, professional_cns:, cbo:, attended_at:, source_id: SecureRandom.uuid)
        raise NotAllowed, "ficha sintética só em development/test" unless Rails.env.local?

        @cnes, @ine, @professional_cns, @cbo = cnes, ine, professional_cns, cbo
        @attended_at = attended_at.in_time_zone
        @source_id = source_id
      end

      def type = "procedimento"
      def competence = attended_at.strftime("%Y%m")
      def source = { type: "synthetic", id: source_id }

      def to_thrift(uuid:)
        Ledi::Version.load!
        ras = Br::Gov::Saude::Esusab::Ras
        header = ras::Common::UnicaLotacaoHeaderThrift.new(
          profissionalCNS: professional_cns, cboCodigo_2002: cbo, cnes: cnes, ine: ine,
          dataAtendimento: ms(attended_at), codigoIbgeMunicipio: CityProfile.current&.ibge_code
        )
        child = ras::Atendprocedimentos::FichaProcedimentoChildThrift.new(
          dtNascimento: ms(CITIZEN_BIRTH.in_time_zone), sexo: 1, localAtendimento: 1, turno: 1,
          cpfCidadao: CITIZEN_CPF, stCidadaoNaoPossuiCpf: false, procedimentos: [ PROCEDURE ],
          dataHoraInicialAtendimento: ms(attended_at), dataHoraFinalAtendimento: ms(attended_at + 10.minutes)
        )
        ras::Atendprocedimentos::FichaProcedimentoMasterThrift.new(
          uuidFicha: uuid, tpCdsOrigem: ORIGIN_THIRD_PARTY, headerTransport: header, atendProcedimentos: [ child ]
        )
      end

      private

      def ms(time) = (time.to_f * 1000).to_i
    end
  end
end
