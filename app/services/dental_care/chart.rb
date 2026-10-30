# Odontograma calculado (ADR 0046; contrato §16 O3): a dobra dos
# dental_chart_events do paciente em (recorded_at, seq), até `as_of`. Por dente:
# a coroa é o último evento de coroa sem face com situação; a raiz, o último de
# raiz com situação; cada face, o último evento daquela face — uma situação de
# coroa que não vale na face (extracted, missing, crown, complete_denture…)
# zera as faces. Evento só com procedimento não muda situação, mas conta em
# notes_count (eventos do dente) e em last_event_at. Dentição pelos dentes
# presentes (com evento e coroa que não é ausência; prótese conta como
# permanente); sem nenhum, pela idade
# (< 6 decídua, 6..12 mista). Dado clínico: só para o corpo JSON.
module DentalCare
  module Chart
    TEETH = (Catalog::PERMANENT_TEETH + Catalog::DECIDUOUS_TEETH).freeze
    ABSENT = %w[missing extracted unerupted].freeze
    # Substituição protética: conta como dentição permanente, nunca decídua.
    PROSTHETIC = %w[complete_denture removable_partial_denture temporary_prosthesis].freeze

    module_function

    def call(patient, as_of: nil)
      scope = DentalChartEvent.where(patient_id: patient.id)
      scope = scope.where(recorded_at: ..as_of) if as_of
      teeth = TEETH.index_with { |tooth| blank(tooth) }
      scope.order(:recorded_at, :seq).pluck(:tooth, :part, :face, :situation, :recorded_at).each do |row|
        fold!(teeth.fetch(row.first), *row.drop(1))
      end
      { dentition: dentition(teeth.values, patient), teeth: teeth.values }
    end

    def blank(tooth)
      { tooth: tooth, situation: nil, root: nil, faces: Catalog::FACES.index_with { nil }, last_event_at: nil, notes_count: 0 }
    end

    def fold!(state, part, face, situation, recorded_at)
      state[:notes_count] += 1
      state[:last_event_at] = recorded_at
      return if situation.nil?

      if part == "root"
        state[:root] = situation
      elsif face
        state[:faces][face] = situation
      else
        state[:situation] = situation
        state[:faces].transform_values! { nil } unless Situations.face_situation?(situation)
      end
    end

    def dentition(teeth, patient)
      present = teeth.select { |t| t[:notes_count].positive? && !ABSENT.include?(t[:situation]) }
      return by_age(patient.age) if present.empty?

      prosthetic, natural = present.partition { |t| PROSTHETIC.include?(t[:situation]) }
      numbers = natural.map { |t| t[:tooth] }
      permanent = prosthetic.any? || numbers.intersect?(Catalog::PERMANENT_TEETH)
      deciduous = numbers.intersect?(Catalog::DECIDUOUS_TEETH)
      return "mixed" if permanent && deciduous

      deciduous ? "deciduous" : "permanent"
    end

    def by_age(age)
      return "permanent" if age.nil?
      return "deciduous" if age < 6

      age <= 12 ? "mixed" : "permanent"
    end
    private_class_method :blank, :fold!, :dentition, :by_age
  end
end
