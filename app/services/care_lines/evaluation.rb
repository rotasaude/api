# Avaliação de uma página (ADR 0040; plano, Desvio 9): carrega as fontes de
# todas as pessoas da página de uma vez (CareLines::Sources) e avalia cada
# uma (CareLines::Evaluate). Nada é gravado. `vaccination`: o interruptor do
# módulo 29 (Vaccination::Gate.usable?), lido pelo chamador fora de transação;
# desligado, a vacina segue não rastreada. `home_visits` (módulo 24b,
# HomeVisits::Gate.usable?): o mesmo, para a visita do ACS e as medidas da visita.
module CareLines
  module Evaluation
    # inspect só com a chave: as práticas trazem due_on (DUM + janela), que revela a DUM.
    Row = Data.define(:key, :practices, :worst) do
      def inspect = "#<CareLines::Evaluation::Row key=#{key.inspect} worst=#{worst}>"
      alias_method :to_s, :inspect
      def pretty_print(q) = q.text(inspect)
      # ActiveSupport faz Data#as_json = to_h.as_json: sem isto o to_json levaria as práticas (due_on, done_at).
      def as_json(*) = { "key" => key, "worst" => worst }
    end

    module_function

    def enrollments(enrollments, today:, vaccination: false, home_visits: false)
      list = enrollments.to_a
      return {} if list.empty?

      ActiveRecord::Associations::Preloader.new(records: list, associations: %i[care_line patient]).call
      items = list.map do |enrollment|
        patient = enrollment.patient
        birth = parse_date(patient.birth_date)
        person = Person.new(patient_id: patient.id, birth_date: birth, sex: patient.sex)
        { key: enrollment.id, practices: enrollment.care_line.practices, person: person,
          anchors: { "enrollment" => enrollment.enrolled_at.in_time_zone.to_date, "birth" => birth, "lmp" => enrollment.anchor_on } }
      end
      items(items, today: today, vaccination: vaccination, home_visits: home_visits)
    end

    def items(items, today:, vaccination: false, home_visits: false)
      flags = { vaccination: vaccination, home_visits: home_visits }
      with_patient = items.select { |item| item[:person].patient_id }
      sources = items.flat_map { |item| item[:practices].flat_map { |p| Evaluate.sources_of(p, **flags) } }.uniq
      since = items.map { |item| Evaluate.since(item[:practices], item[:anchors], today, **flags) }.min || today
      events = Sources.load(patient_ids: with_patient.map { |item| item[:person].patient_id }, sources: sources, since: since,
                            home_visits: home_visits)
      items.to_h do |item|
        statuses = Evaluate.call(practices: item[:practices], person: item[:person], anchors: item[:anchors],
                                 events: events.fetch(item[:person].patient_id, {}), today: today, **flags)
        [ item[:key], Row.new(key: item[:key], practices: statuses, worst: Evaluate.worst(statuses)) ]
      end
    end

    def parse_date(value)
      value.present? ? Date.iso8601(value) : nil
    rescue Date::Error
      nil
    end
  end
end
