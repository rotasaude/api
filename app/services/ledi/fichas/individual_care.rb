# app/services/ledi/fichas/individual_care.rb
# Consulta da APS como Atendimento Individual (ADR 0031; spec §6; Task 1):
# tipo de atendimento, problemas avaliados com situação (uuid do problema,
# da evolução e sequência), condutas, exames solicitados (SIGTAP grupo 02,
# "S"), medições, início e fim; só o CPF do cidadão. Sem medicamento nem texto
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
        common = Br::Gov::Saude::Esusab::Ras::Common
        ai = Br::Gov::Saude::Esusab::Ras::Atendindividual
        header = common::VariasLotacoesHeaderThrift.new(
          lotacaoFormPrincipal: common::LotacaoHeaderThrift.new(profissionalCNS: identity.professional_cns,
                                                                cboCodigo_2002: identity.cbo, cnes: identity.cnes,
                                                                ine: identity.ine),
          dataAtendimento: ms(identity.started_at), codigoIbgeMunicipio: identity.ibge_code
        )
        child = ai::FichaAtendimentoIndividualChildThrift.new(
          dataNascimento: ms(identity.birth_date.in_time_zone), localDeAtendimento: CM.local_de_atendimento,
          sexo: SM.sex_code(identity.sex), turno: SM.turno(identity.started_at), tipoAtendimento: care.care_type,
          condutas: care.conducts, dataHoraInicialAtendimento: ms(identity.started_at),
          dataHoraFinalAtendimento: ms(identity.ended_at), cpfCidadao: identity.citizen_cpf, stCidadaoNaoPossuiCpf: false,
          ficouEmObservacao: false, medicoes: care.measurements && Medicoes.build(care.measurements),
          problemasCondicoes: sent_problems.map { |p| problem(common, p) },
          exame: care.exams.empty? ? nil : care.exams.map { |code| common::ExameThrift.new(codigoExame: code, solicitadoAvaliado: [ CM.exam_requested ]) }
        )
        ai::FichaAtendimentoIndividualMasterThrift.new(uuidFicha: uuid, tpCdsOrigem: ORIGIN_THIRD_PARTY,
                                                       headerTransport: header, atendimentosIndividuais: [ child ])
      end

      private

      def sent_problems
        return care.problems if CM.cid10_allowed?(identity.cbo)

        care.problems.select { |p| p.cid10.nil? }
      end

      def problem(common, p)
        common::ProblemaCondicaoThrift.new(
          uuidProblema: p.uuid, uuidEvolucaoProblema: p.evolution_uuid, coSequencialEvolucao: p.sequence, ciap: p.ciap,
          cid10: p.cid10, situacao: p.situation, dataInicioProblema: p.onset_on && ms(onset(p.onset_on).in_time_zone),
          dataFimProblema: p.resolved_on && ms(p.resolved_on.in_time_zone), isAvaliado: true
        )
      end

      # Regra LEDI: dataInicioProblema >= nascimento (início com precisão de mês
      # ou ano grava o dia 1, que pode cair antes do nascimento).
      def onset(date) = [ date, identity.birth_date ].max

      def ms(time) = (time.to_f * 1000).to_i
    end
  end
end
