require "base64"

# "Quem visitar" por microárea (módulo 24b, ADR 0052; contrato §8, §16 Q33;
# plano, Task 18). População = cadastro individual ativo (24a) com domicílio
# na microárea, menos os óbitos (CareLines::Facts.deceased). Motivos:
#   - care_line: inscrição ativa com prática de fonte acs_visit em overdue ou
#     due_soon (CareLines::Evaluation com `home_visits:`), só com `care_lines`
#     utilizável; só o nome da linha, o rótulo da prática, o status e o
#     due_on — nunca CID, problema ou condição;
#   - registration_due: TerritoryRegistry::Validity em due_soon ou expired;
#   - never_visited: nenhuma visita não retirada com outcome = 1 do paciente.
# Só entra quem tem ao menos um motivo. Ordem display_name (sem acento nem
# caixa), patient_id: o nome é cifrado, então a ordem e o corte da página são
# feitos em Ruby sobre a microárea inteira, com consultas constantes (nada por
# paciente; listas de ids vão ao banco como subconsulta ou bind). O cursor é
# o person_ref opaco (base64url de "patient:<id>"): a posição sai do nome do
# paciente do cursor, mesmo que ele tenha saído da lista. Interruptores lidos
# pelo chamador, fora de transação. `limit: nil` = a lista toda (download do
# app, Task 22). Sem trilha aqui: a rota grava a sua, a contagem não grava.
module HomeVisits
  module WhoToVisit
    REASONS = %w[care_line registration_due never_visited].freeze
    CARE_LINE_STATUSES = %w[overdue due_soon].freeze
    REGISTRATION_STATUSES = %w[due_soon expired].freeze
    SOURCE = "acs_visit".freeze
    PERSON_REF = /\Apatient:(\h{8}-\h{4}-\h{4}-\h{4}-\h{12})\z/
    InvalidCursor = Class.new(StandardError)

    # Os motivos trazem due_on (DUM + janela, vencimento do cadastro): fora do inspect e do as_json.
    Entry = Data.define(:patient_id, :household_id, :family_id, :last_visit_on, :reasons) do
      def codes = reasons.map { |reason| reason[:code] }.uniq
      def inspect = "#<HomeVisits::WhoToVisit::Entry patient_id=#{patient_id}>"
      alias_method :to_s, :inspect
      def pretty_print(q) = q.text(inspect)
      def as_json(*) = { "patient_id" => patient_id }
    end

    module_function

    # { items: [<item do §8>], next_before: cursor | nil }. `before`: o cursor
    # opaco (InvalidCursor se não for um). `reasons`: só quem tem ao menos um
    # desses códigos (com todos os seus motivos).
    def page(micro_area:, before:, limit:, today:, care_lines:, home_visits:, reasons: nil)
      after = before.nil? ? nil : decode_cursor(before)
      list = entries(micro_area: micro_area, today: today, care_lines: care_lines, home_visits: home_visits)
      list = list.select { |entry| entry.codes.intersect?(reasons) } if reasons
      patients = list.empty? ? {} : names(micro_area)
      rows = list.sort_by { |entry| sort_key(patients.fetch(entry.patient_id)) }
      if after
        position = sort_key(patients[after] || Patient.select(:id, :full_name, :social_name, :unidentified).find_by(id: after) ||
                            raise(InvalidCursor))
        rows = rows.select { |entry| (sort_key(patients.fetch(entry.patient_id)) <=> position) == 1 }
      end
      shown = limit ? rows.first(limit) : rows
      more = limit && rows.size > limit
      { items: items(shown, patients, micro_area, today), next_before: more ? encode_cursor(shown.last.patient_id) : nil }
    end

    # { care_line:, registration_due:, never_visited:, people: } — pessoas com
    # cada motivo e com algum.
    def count(micro_area:, today:, care_lines:, home_visits:)
      list = entries(micro_area: micro_area, today: today, care_lines: care_lines, home_visits: home_visits)
      REASONS.to_h { |code| [ code.to_sym, list.count { |entry| entry.codes.include?(code) } ] }.merge(people: list.size)
    end

    # [Entry] de quem tem ao menos um motivo, sem ordem.
    def entries(micro_area:, today:, care_lines:, home_visits:)
      scope = population(micro_area)
      rows = scope.joins(:patient).pluck(:patient_id, :household_id, :family_id, :registered_at, :refused,
                                         Arel.sql("patients.cpf IS NOT NULL OR patients.cns IS NOT NULL"))
      return [] if rows.empty?

      dead = CareLines::Facts.deceased(rows.map(&:first))
      visited = HomeVisit.valid.where(outcome: 1, patient_id: scope.select(:patient_id)).group(:patient_id).maximum(:occurred_at)
      care = care_lines ? care_line_reasons(scope, today: today, home_visits: home_visits) : {}
      rows.filter_map do |patient_id, household_id, family_id, registered_at, refused, identified|
        next if dead.include?(patient_id)

        last = visited[patient_id]
        reasons = care.fetch(patient_id, []) + registration_reasons(registered_at, refused == "true", identified, today)
        reasons << { code: "never_visited" } unless last
        next if reasons.empty?

        Entry.new(patient_id: patient_id, household_id: household_id, family_id: family_id,
                  last_visit_on: last&.in_time_zone&.to_date&.iso8601, reasons: reasons)
      end
    end

    def encode_cursor(patient_id) = Base64.urlsafe_encode64("patient:#{patient_id}", padding: false)

    # O patient_id do cursor; qualquer outra coisa → InvalidCursor.
    def decode_cursor(raw)
      raise InvalidCursor unless raw.is_a?(String) && !raw.empty?

      match = Base64.urlsafe_decode64(raw).match(PERSON_REF)
      raise InvalidCursor unless match

      match[1].downcase
    rescue ArgumentError, EncodingError
      raise InvalidCursor
    end

    def population(micro_area)
      IndividualRegistration.active_registrations.where(micro_area_id: micro_area.id).where.not(household_id: nil)
    end

    # { patient_id => [motivo care_line] }: as inscrições ativas da população
    # em linhas com prática acs_visit, avaliadas de uma vez; linha por nome.
    def care_line_reasons(scope, today:, home_visits:)
      enrollments = CareLineEnrollment.active_enrollments.where(patient_id: scope.select(:patient_id)).includes(:care_line).to_a
      enrollments.select! { |enrollment| enrollment.care_line.practices.any? { |practice| practice["source"] == SOURCE } }
      evaluated = CareLines::Evaluation.enrollments(enrollments, today: today, home_visits: home_visits)
      enrollments.sort_by { |enrollment| [ enrollment.care_line.name, enrollment.id ] }.each_with_object({}) do |enrollment, by_patient|
        evaluated.fetch(enrollment.id).practices.each do |status|
          next unless status.source == SOURCE && CARE_LINE_STATUSES.include?(status.status)

          # Prática vencida sem prazo calculado (janela móvel nunca cumprida, âncora ausente): vence hoje.
          (by_patient[enrollment.patient_id] ||= []) << { code: "care_line", care_line: enrollment.care_line.name, practice: status.label,
                                                          status: status.status, due_on: (status.due_on || today).iso8601 }
        end
      end
    end

    def registration_reasons(registered_at, refused, identified, today)
      status = TerritoryRegistry::Validity.status_of(registered_at: registered_at, refused: refused, identified: identified, today: today)
      return [] unless REGISTRATION_STATUSES.include?(status)

      [ { code: "registration_due", status: status, due_on: TerritoryRegistry::Validity.expires_on(registered_at).iso8601 } ]
    end

    # { patient_id => Patient } da microárea, só com o que o nome e a idade pedem.
    def names(micro_area)
      Patient.where(id: population(micro_area).select(:patient_id)).select(:id, :full_name, :social_name, :unidentified, :birth_date)
             .index_by(&:id)
    end

    def sort_key(patient) = [ I18n.transliterate(patient.display_name.to_s).downcase, patient.id ]

    def items(entries, patients, micro_area, today)
      addresses = Json.addresses(entries.map(&:household_id))
      entries.map do |entry|
        patient = patients.fetch(entry.patient_id)
        { patient_id: entry.patient_id, display_name: patient.display_name, age: patient.age(on: today),
          household: entry.household_id && { id: entry.household_id, address_short: addresses[entry.household_id] || "Sem endereço" },
          family_id: entry.family_id, micro_area: { id: micro_area.id, code: micro_area.code }, last_visit_on: entry.last_visit_on,
          reasons: entry.reasons }
      end
    end

    private_class_method :population, :care_line_reasons, :registration_reasons, :names, :sort_key, :items
  end
end
