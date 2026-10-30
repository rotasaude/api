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
      def procedures = ::DentalCare::ProcedureLimits.sums(care.procedures).sort

      def to_thrift(uuid:)
        Ledi::Version.load!
        fao = Br::Gov::Saude::Esusab::Ras::Atendodonto
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
          problemasCondicoes: sent_problems.map { |p| Common.problem(p, identity.birth_date) }, exame: Common.exams(care.exams),
          medicoes: care.measurements && Medicoes.build(care.measurements),
          sexo: SM.sex_code(identity.sex), turno: SM.turno(identity.started_at),
          dataHoraInicialAtendimento: ms(identity.started_at), dataHoraFinalAtendimento: ms(identity.ended_at)
        )
        fao::FichaAtendimentoOdontologicoMasterThrift.new(uuidFicha: uuid, tpCdsOrigem: ORIGIN_THIRD_PARTY,
                                                          headerTransport: Common.header(identity), atendimentosOdontologicos: [ child ])
      end

      private

      def male? = identity.sex == "male"

      # Desvio 9: o dentista (2232*) leva o CID-10; o TSB/ASB só o CIAP-2.
      def sent_problems
        return care.problems if ::Consultations::Cbos.role(identity.cbo) == :dentist

        care.problems.select { |p| p.cid10.nil? }
      end

      def ms(time) = Common.ms(time)
    end
  end
end
