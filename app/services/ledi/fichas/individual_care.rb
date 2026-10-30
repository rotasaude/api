# app/services/ledi/fichas/individual_care.rb
# Consulta da APS como Atendimento Individual (ADR 0031; spec §6; Task 1):
# tipo de atendimento, problemas avaliados com situação (uuid do problema,
# da evolução e sequência), condutas, exames solicitados (SIGTAP grupo 02,
# "S"), medições, início e fim; o CPF do cidadão ou, sem CPF, o CNS (nunca os
# dois; stCidadaoNaoPossuiCpf = sem CPF, com a justificativa — módulo 24a). Sem medicamento nem texto
# SOAP. Pura: recebe valores (Ledi::ConsultationFicha monta). Implementa
# Ledi::Ficha. Consulta de não médico: o problema em CID-10 fica fora da ficha
# (só CIAP-2, como no PEC); o prontuário não muda.
module Ledi
  module Fichas
    class IndividualCare
      ORIGIN_THIRD_PARTY = 3
      CM = Ledi::ConsultationMapping
      SM = Ledi::ScreeningMapping

      Problem = Data.define(:uuid, :evolution_uuid, :sequence, :ciap, :cid10, :situation, :onset_on, :resolved_on)
      Care = Data.define(:care_type, :problems, :conducts, :exams, :measurements)

      attr_reader :identity, :care, :source_id

      def initialize(identity:, care:, source_id:)
        @identity, @care, @source_id = identity, care, source_id
      end

      def type = "atendimento_individual"
      def competence = identity.started_at.in_time_zone.strftime("%Y%m")
      def cnes = identity.cnes
      def ine = identity.ine
      def source = { type: "Consultation", id: source_id }

      def to_thrift(uuid:)
        Ledi::Version.load!
        ai = Br::Gov::Saude::Esusab::Ras::Atendindividual
        child = ai::FichaAtendimentoIndividualChildThrift.new(
          dataNascimento: ms(identity.birth_date.in_time_zone), localDeAtendimento: CM.local_de_atendimento,
          sexo: SM.sex_code(identity.sex), turno: SM.turno(identity.started_at), tipoAtendimento: care.care_type,
          condutas: care.conducts, dataHoraInicialAtendimento: ms(identity.started_at),
          dataHoraFinalAtendimento: ms(identity.ended_at), cpfCidadao: identity.citizen_cpf, cns: identity.citizen_cns,
          stCidadaoNaoPossuiCpf: identity.citizen_cpf.nil?,
          justificativaCidadaoNaoPossuiCpf: (identity.citizen_no_cpf_reason if identity.citizen_cpf.nil?),
          ficouEmObservacao: false, medicoes: care.measurements && Medicoes.build(care.measurements),
          problemasCondicoes: sent_problems.map { |p| Common.problem(p, identity.birth_date) }, exame: Common.exams(care.exams)
        )
        ai::FichaAtendimentoIndividualMasterThrift.new(uuidFicha: uuid, tpCdsOrigem: ORIGIN_THIRD_PARTY,
                                                       headerTransport: Common.header(identity), atendimentosIndividuais: [ child ])
      end

      private

      def sent_problems
        return care.problems if CM.cid10_allowed?(identity.cbo)

        care.problems.select { |p| p.cid10.nil? }
      end

      def ms(time) = Common.ms(time)
    end
  end
end
