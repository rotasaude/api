# Ficha de Atividade Coletiva de cada atividade (CollectiveActivity; módulo
# 24b, ADR 0052; contrato §11, §16 Q4, Q38, Q41, Q42; plano, Task 14). Uma
# atividade = uma ficha, gerada DENTRO da transação da gravação
# (CollectiveActivities::Record). Reaproveita de Ledi::RegistrationFicha o
# record_failure!/retry!/regenerate e a regra da exportação utilizável
# (inclusive city_profile_incomplete com a exportação aceitando); sobrescreve:
#   - generate: exige a cidade (Current.city, do CityConnection.with — nunca
#     atribuída aqui);
#   - build: a atividade não é versão de cadastro (sem saved_by_*, sem
#     originadora). Cabeçalho = quem registrou (CNS), o CBO do vínculo na
#     gravação, INE da equipe, CNES de health_unit_id, o held_on às 00h no fuso
#     da cidade e o IBGE do perfil.
# Participante: o CPF; sem CPF, o marcador com a justificativa (2–13) e o CNS
# quando houver. Nos tipos 5 e 6 o CNS é obrigatório sem CPF: sem os dois →
# participant_without_identifier. Fora deles o participante entra sem documento
# (Q42), e numAvaliacoesAlteradas segue igual à lista (Q38). Nascimento e sexo
# em todo participante. "Não gerada" pela lista fechada
# CollectiveActivities::Catalog::NOT_GENERATED, nessa ordem. "Registrada por
# engano" não desfaz a ficha já enfileirada (spec §9).
module Ledi
  module CollectiveActivityFicha
    extend Ledi::RegistrationFicha

    SOURCE_TYPE = Ledi::Fichas::CollectiveActivity::SOURCE_TYPE
    LEDI_TABLE = :collective_activity # Tabela 5 do cbo.html (config/ledi/registration_cbos.yml)
    PROFILE_FIELDS = %i[ibge_code].freeze
    JUSTIFICATIONS = TerritoryRegistry::Catalog::NO_CPF_REASONS.map(&:to_i).freeze
    IDENTIFIER_TYPES = CollectiveActivities::Catalog::PARTICIPANTS_REQUIRED

    class << self
      def version_class = ::CollectiveActivity
      def ficha_class = Ledi::Fichas::CollectiveActivity

      # :enqueued | :failed | :unusable | :exists.
      def generate(activity, city: Current.city)
        raise ArgumentError, "Ledi::CollectiveActivityFicha.generate precisa da cidade (CityConnection.with)" unless city

        super
      end

      # [ficha, []] ou [nil, motivos na ordem de NOT_GENERATED].
      def build(activity)
        codes = []
        unit = activity.health_unit
        codes << "unit_without_cnes" if unit.cnes.blank?
        codes << "professional_without_cns" unless Professionals::Cns.valid?(activity.professional.cns)
        # Defesa: o CollectiveActivities::Access já recusa quem não é da Tabela 5.
        codes << "cbo_not_in_ledi_table" unless TerritoryRegistry::Access.registrar_cbo?(activity.cbo, ficha: LEDI_TABLE)
        codes << "city_profile_incomplete" if profile_incomplete?
        codes << "siaps_deadline_passed" if Ledi::Deadline.on(activity.held_on.strftime("%Y%m")) < Time.zone.today
        place = activity.place_health_unit
        # Defesa: o Record recusa a unidade do local sem CNES (path place_health_unit_id).
        codes << "place_without_cnes" if place && place.cnes.blank?
        professionals = professional_rows(activity, codes)
        participants = participant_rows(activity, codes)
        reasons = CollectiveActivities::Catalog::NOT_GENERATED & codes
        return [ nil, reasons ] if reasons.any?

        header = Ledi::Fichas::RegistrationHeader.new(
          cnes: unit.cnes, ine: activity.team.ine, professional_cns: activity.professional.cns, cbo: activity.cbo,
          saved_at: activity.held_on.in_time_zone.beginning_of_day, ibge_code: CityProfile.current&.ibge_code
        )
        [ ficha_class.new(header: header, held_on: activity.held_on, values: activity_values(activity, place),
                          professionals: professionals, participants: participants, source_id: activity.id), [] ]
      end

      private

      def activity_values(activity, place)
        {
          "activity_type" => activity.activity_type, "shift" => activity.shift,
          "place_text" => (activity.place_text unless place), "place_cnes" => place&.cnes,
          "participants_count" => activity.participants_count, "altered_count" => activity.altered_count,
          "meeting_topics" => activity.meeting_topics, "target_audience" => activity.target_audience,
          "health_topics" => activity.health_topics, "health_practices" => activity.health_practices,
          "procedure_code" => activity.procedure_code
        }
      end

      # Profissionais que participaram (não inclui quem registrou): CNS válido e
      # o CBO do vínculo gravado na atividade.
      def professional_rows(activity, codes)
        activity.professionals.includes(:professional).order(:created_at, :id).map do |row|
          cns = row.professional.cns
          codes << "participant_professional_without_cns" unless Professionals::Cns.valid?(cns)
          { "cns" => cns, "cbo" => row.cbo }
        end
      end

      def participant_rows(activity, codes)
        required = IDENTIFIER_TYPES.include?(activity.activity_type)
        activity.participants.includes(:patient).order(:created_at, :id).map do |row|
          patient = row.patient
          document = document(patient)
          codes << "participant_without_identifier" if required && !(document["cpf"] || document["cns"])
          birth_date = TerritoryRegistry::Dictionary.iso_date(patient.birth_date)
          codes << "participant_without_birth_date" unless birth_date
          sex = TerritoryRegistry::Catalog::SEX_TO_LEDI[patient.sex]
          codes << "participant_without_sex" unless sex
          document.merge("birth_date" => birth_date, "sex" => sex, "altered_evaluation" => row.altered_evaluation == true,
                         "measurements" => row.measurements, "smoking" => row.smoking)
        end
      end

      # CPF xor (marcador, justificativa 2–13, CNS se houver). O marcador exige a
      # justificativa e o CNS só vai com o marcador (dicionario-fac.html): sem
      # justificativa válida (o provisório da UPA, que o Record já recusa) não
      # vai documento algum — nunca inventado.
      def document(patient)
        found = Ledi::Fichas::CitizenDocument.for(patient)
        return { "cpf" => found[:cpf], "cns" => nil, "no_cpf" => false, "justification" => nil } if found[:cpf]
        return { "cpf" => nil, "cns" => nil, "no_cpf" => nil, "justification" => nil } if patient.unidentified ||
                                                                                       !JUSTIFICATIONS.include?(found[:justification])

        { "cpf" => nil, "cns" => found[:cns], "no_cpf" => true, "justification" => found[:justification] }
      end
    end
  end
end
