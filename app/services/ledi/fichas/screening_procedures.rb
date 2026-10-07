# Escuta por técnico/auxiliar de enfermagem como Ficha de Procedimentos (ADR
# 0030; spec §5; Task 1): marca de escuta inicial, SIGTAP das aferições feitas
# (nunca 03.01.04.007-9) e medições. Decisão D10 do product owner
# (2026-10-07, substitui spec §5): sem aferição a ficha AINDA nasce, só com a
# marca; procedimentos e medicoes ficam ausentes (nil), nunca listas vazias
# (screening_procedures.flag_only_accepted no mapeamento).
module Ledi
  module Fichas
    class ScreeningProcedures
      ORIGIN_THIRD_PARTY = 3
      M = Ledi::ScreeningMapping
      # Aferição → coluna que prova que ela foi feita.
      MEASURED = { "blood_pressure" => "systolic", "capillary_glucose" => "capillary_glucose",
                   "temperature" => "temperature_c", "weight" => "weight_kg", "height" => "height_cm" }.freeze

      def self.procedures(revision)
        MEASURED.filter_map { |kind, column| M.procedure(kind) unless revision[column].nil? }
      end

      # D10: a marca de escuta basta; quem decide MIP vs MIAI é o CBO (Task 14).
      def self.applicable?(_revision) = true

      attr_reader :identity, :revision, :source_id

      def initialize(identity:, revision:, source_id:)
        @identity, @revision, @source_id = identity, revision, source_id
      end

      def type = "procedimento"
      def competence = identity.started_at.in_time_zone.strftime("%Y%m")
      def cnes = identity.cnes
      def ine = identity.ine
      def source = { type: "Screening", id: source_id }

      def to_thrift(uuid:)
        Ledi::Version.load!
        ras = Br::Gov::Saude::Esusab::Ras
        header = ras::Common::UnicaLotacaoHeaderThrift.new(
          profissionalCNS: identity.professional_cns, cboCodigo_2002: identity.cbo, cnes: identity.cnes,
          ine: identity.ine, dataAtendimento: ms(identity.started_at), codigoIbgeMunicipio: identity.ibge_code
        )
        child = ras::Atendprocedimentos::FichaProcedimentoChildThrift.new(
          dtNascimento: ms(identity.birth_date.in_time_zone), sexo: M.sex_code(identity.sex),
          localAtendimento: M.value("screening_procedures.local_atendimento"), turno: M.turno(identity.started_at),
          statusEscutaInicialOrientacao: M.value("screening_procedures.status_escuta_inicial_orientacao"),
          procedimentos: self.class.procedures(revision).presence, dataHoraInicialAtendimento: ms(identity.started_at),
          dataHoraFinalAtendimento: ms(identity.ended_at), cpfCidadao: identity.citizen_cpf,
          stCidadaoNaoPossuiCpf: false, medicoes: Medicoes.build(revision)
        )
        ras::Atendprocedimentos::FichaProcedimentoMasterThrift.new(uuidFicha: uuid, tpCdsOrigem: ORIGIN_THIRD_PARTY,
                                                                   headerTransport: header, atendProcedimentos: [ child ])
      end

      private

      def ms(time) = (time.to_f * 1000).to_i
    end
  end
end
