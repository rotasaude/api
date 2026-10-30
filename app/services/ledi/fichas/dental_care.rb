# app/services/ledi/fichas/dental_care.rb
# Consulta odontológica como Atendimento Odontológico Individual (FAO; ADR
# 0046; F-28.2; vendor/ledi/8.7.0/docs/dicionario-fao.html): tipo de
# atendimento, tipo de consulta (0 ou 1), vigilância, fornecimento, condutas e
# encaminhamentos (dental_outcomes), gestante (omitido no sexo masculino — "não
# pode ser preenchido quando Sexo = 0"), necessidades especiais, procedimentos
# agregados por SIGTAP (soma das quantidades; a finalização já recusou mais de
# 20 códigos ou soma acima do limite do local), problemas avaliados (o dentista
# leva CID-10, Desvio 9; TSB/ASB só CIAP-2), exames solicitados, medições,
# início e fim; o CPF do cidadão ou, sem CPF, o CNS (nunca os dois). INE nulo
# no CEO (o especialista não está em equipe; Review Focus 2). Pura: recebe
# valores (Ledi::ConsultationFicha monta). Implementa Ledi::Ficha.
module Ledi
  module Fichas
    class DentalCare
      ORIGIN_THIRD_PARTY = 3
      CM = Ledi::ConsultationMapping
      SM = Ledi::ScreeningMapping
      Problem = IndividualCare::Problem

      # procedures: pares [SIGTAP, quantidade], um por procedimento da consulta.
      Care = Data.define(:care_type, :consultation_type, :surveillance, :supplies, :outcomes, :pregnant, :special_needs,
                         :procedures, :problems, :exams, :measurements)

      attr_reader :identity, :care, :source_id

      def initialize(identity:, care:, source_id:)
        @identity, @care, @source_id = identity, care, source_id
      end

      def type = "atendimento_odontologico"
      def competence = identity.started_at.in_time_zone.strftime("%Y%m")
      def cnes = identity.cnes
      def ine = identity.ine
      def source = { type: "Consultation", id: source_id }

      # [[SIGTAP, soma das quantidades]], na ordem do código.
      def procedures
        care.procedures.each_with_object(Hash.new(0)) { |(code, quantity), acc| acc[code] += quantity }.sort
      end

      def to_thrift(uuid:)
        Ledi::Version.load!
        common = Br::Gov::Saude::Esusab::Ras::Common
        fao = Br::Gov::Saude::Esusab::Ras::Atendodonto
        header = common::VariasLotacoesHeaderThrift.new(
          lotacaoFormPrincipal: common::LotacaoHeaderThrift.new(profissionalCNS: identity.professional_cns,
                                                                cboCodigo_2002: identity.cbo, cnes: identity.cnes,
                                                                ine: identity.ine),
          dataAtendimento: ms(identity.started_at), codigoIbgeMunicipio: identity.ibge_code
        )
        no_cpf = identity.citizen_cpf.nil?
        child = fao::FichaAtendimentoOdontologicoChildThrift.new(
          dtNascimento: ms(identity.birth_date.in_time_zone), cpfCidadao: identity.citizen_cpf, cnsCidadao: identity.citizen_cns,
          stCidadaoNaoPossuiCpf: no_cpf, justificativaCidadaoNaoPossuiCpf: (identity.citizen_no_cpf_reason if no_cpf),
          gestante: (care.pregnant unless male?), necessidadesEspeciais: care.special_needs,
          localAtendimento: CM.local_de_atendimento, tipoAtendimento: care.care_type,
          tiposConsultaOdonto: care.consultation_type && [ care.consultation_type ],
          tiposVigilanciaSaudeBucal: care.surveillance, tiposFornecimOdonto: care.supplies.presence,
          tiposEncamOdonto: care.outcomes,
          procedimentosRealizados: procedures.presence&.map { |code, quantity| fao::ProcedimentoQuantidadeThrift.new(coMsProcedimento: code, quantidade: quantity) },
          problemasCondicoes: sent_problems.map { |p| problem(common, p) },
          exame: care.exams.empty? ? nil : care.exams.map { |code| common::ExameThrift.new(codigoExame: code, solicitadoAvaliado: [ CM.exam_requested ]) },
          medicoes: care.measurements && Medicoes.build(care.measurements),
          sexo: SM.sex_code(identity.sex), turno: SM.turno(identity.started_at),
          dataHoraInicialAtendimento: ms(identity.started_at), dataHoraFinalAtendimento: ms(identity.ended_at)
        )
        fao::FichaAtendimentoOdontologicoMasterThrift.new(uuidFicha: uuid, tpCdsOrigem: ORIGIN_THIRD_PARTY,
                                                          headerTransport: header, atendimentosOdontologicos: [ child ])
      end

      private

      def male? = identity.sex == "male"

      # Desvio 9: o dentista (2232*) leva o CID-10; o TSB/ASB só o CIAP-2.
      def sent_problems
        return care.problems if Consultations::Cbos.role(identity.cbo) == :dentist

        care.problems.select { |p| p.cid10.nil? }
      end

      def problem(common, p)
        common::ProblemaCondicaoThrift.new(
          uuidProblema: p.uuid, uuidEvolucaoProblema: p.evolution_uuid, coSequencialEvolucao: p.sequence, ciap: p.ciap,
          cid10: p.cid10, situacao: p.situation, dataInicioProblema: p.onset_on && ms([ p.onset_on, identity.birth_date ].max.in_time_zone),
          dataFimProblema: p.resolved_on && ms(p.resolved_on.in_time_zone), isAvaliado: true
        )
      end

      def ms(time) = (time.to_f * 1000).to_i
    end
  end
end
