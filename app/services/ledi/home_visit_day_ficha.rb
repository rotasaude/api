# Ficha de Visita Domiciliar e Territorial de cada folha do dia (HomeVisitDay;
# módulo 24b, ADR 0052; contrato §10; plano, Task 9, Ruling A8). Reaproveita de
# Ledi::RegistrationFicha o record_failure!/retry!/regenerate e a regra da
# exportação utilizável (inclusive city_profile_incomplete com a exportação
# aceitando); sobrescreve:
#   - generate: folha sem visita válida (todas retiradas) → :empty, antes do
#     :exists e sem gravar nada (nem ficha, nem "não gerada"); exige a cidade
#     (Current.city, do CityConnection.with — nunca atribuída aqui);
#   - build: a folha não é versão de cadastro (sem saved_by_*, sem originadora).
#     Cabeçalho = dono da folha (CNS), CBO da folha (vínculo na abertura), INE e
#     CNES da equipe, o dia às 00h no fuso da cidade (W-10) e o IBGE do perfil.
# "Não gerada" pela lista fechada HomeVisits::Catalog::NOT_GENERATED (Q4): uma
# visita com problema segura a folha inteira; `blockers` diz qual (sem gravar).
# Quem chama: o fechamento da folha (HomeVisits::CloseDay, dentro da transação).
module Ledi
  module HomeVisitDayFicha
    extend Ledi::RegistrationFicha

    SOURCE_TYPE = Ledi::Fichas::HomeVisitDay::SOURCE_TYPE
    LEDI_TABLE = :home_visit # Tabela 7 do cbo.html (config/ledi/registration_cbos.yml)
    PROFILE_FIELDS = %i[ibge_code].freeze
    JUSTIFICATIONS = TerritoryRegistry::Catalog::NO_CPF_REASONS.map(&:to_i).freeze

    class << self
      def version_class = ::HomeVisitDay
      def ficha_class = Ledi::Fichas::HomeVisitDay

      # :empty | :enqueued | :failed | :unusable | :exists.
      def generate(day, city: Current.city)
        raise ArgumentError, "Ledi::HomeVisitDayFicha.generate precisa da cidade (CityConnection.with)" unless city
        return :empty unless day.home_visits.valid.exists?

        super
      end

      # [ficha, []] ou [nil, motivos na ordem de NOT_GENERATED].
      def build(day)
        visits, blockers = check(day)
        reasons = HomeVisits::Catalog::NOT_GENERATED & blockers.map { |row| row[:code] }
        return [ nil, reasons ] if reasons.any?

        header = Ledi::Fichas::RegistrationHeader.new(
          cnes: day.team.health_unit.cnes, ine: day.team.ine, professional_cns: day.professional.cns, cbo: day.cbo,
          saved_at: day.day.in_time_zone.beginning_of_day, ibge_code: CityProfile.current&.ibge_code
        )
        [ ficha_class.new(header: header, day: day.day, visits: visits, source_id: day.id), [] ]
      end

      # [{ code:, visit_id: }] — os motivos do build, sem gravar; visit_id nulo
      # nos da folha (unidade, profissional, CBO, perfil, prazo).
      def blockers(day) = check(day).last

      private

      def check(day)
        blockers = []
        add = ->(code, visit = nil) { blockers << { code: code, visit_id: visit&.id } }
        add.("unit_without_cnes") if day.team.health_unit.cnes.blank?
        add.("professional_without_cns") unless Professionals::Cns.valid?(day.professional.cns)
        # Defesa: o HomeVisits::Access já recusa quem não é da Tabela 7.
        add.("cbo_not_in_ledi_table") unless TerritoryRegistry::Access.registrar_cbo?(day.cbo, ficha: LEDI_TABLE)
        add.("city_profile_incomplete") if profile_incomplete?
        add.("siaps_deadline_passed") if Ledi::Deadline.on(day.competence) < Time.zone.today
        visits = day.home_visits.valid.includes(:patient, :micro_area, :household).order(:occurred_at, :id).map do |visit|
          row, codes = visit_values(visit)
          codes.each { |code| add.(code, visit) }
          row
        end
        [ visits, blockers ]
      end

      # [valores da visita, motivos]. patient_id é sempre a pessoa da ficha: o
      # morador, ou o responsável em family_responsible (contrato §1, C5, Q40).
      def visit_values(visit)
        row = {
          "shift" => visit.shift, "outcome" => visit.outcome, "reasons" => Array(visit.reasons).map(&:to_i),
          "shared" => visit.shared, "property_type" => visit.property_type, "out_of_area" => visit.out_of_area,
          "micro_area_code" => (visit.micro_area&.code unless visit.out_of_area), "measurements" => visit.measurements.to_h,
          "household_origin_uuid" => household_origin_uuid(visit.household)
        }
        patient = visit.patient or return [ row, [] ]

        codes = []
        document = Ledi::Fichas::CitizenDocument.for(patient)
        # Sem CPF, o marcador exige a justificativa 2–13 (o CNS não é obrigatório
        # na FVD, Task 1); o provisório da UPA ("unidentified") não tem nenhuma.
        identified = !patient.unidentified && (document[:cpf] || JUSTIFICATIONS.include?(document[:justification]))
        codes << "patient_without_identifier" unless identified
        birth_date = TerritoryRegistry::Dictionary.iso_date(patient.birth_date)
        codes << "citizen_without_birth_date" unless birth_date
        sex = TerritoryRegistry::Catalog::SEX_TO_LEDI[patient.sex]
        codes << "citizen_without_sex" unless sex
        row["person"] = { "cpf" => document[:cpf], "cns" => document[:cns], "no_cpf" => document[:no_cpf],
                          "justification" => document[:justification], "birth_date" => birth_date, "sex" => sex }
        [ row, codes ]
      end

      # A originadora da ficha domiciliar (a mais antiga utilizável do domicílio),
      # pela versão atual; sem domicílio ou sem ficha utilizável, nil (nunca inventado).
      def household_origin_uuid(household)
        version = household&.latest_version or return nil

        Ledi::HouseholdRegistrationFicha.originating_uuid(version)
      end
    end
  end
end
