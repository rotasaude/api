# Internação do paciente no destino (contrato §6; §14 T10; plano, Desvio 12):
# guardada em tfd_cases.inpatient_stays (jsonb, [ { "from", "to" } ] em ISO,
# pela data de entrada). Só em `scheduled` ou `travelling`, pela comissão.
#   `from` sem aberta     abre (ou grava fechada, com `to`);
#   `from` = o da aberta  com `to`, fecha a aberta; sem `to`, nada muda;
#   `from` ≠ o da aberta  inpatient_open;
#   cruza outra           inpatient_overlap (intervalo meio-aberto [from, to),
#                         aberta até o infinito; entrada no dia da alta vale);
#   `to` < `from`         invalid_request (path "to").
# Grava o evento `inpatient_recorded` sem mudar a situação e publica
# tfd.case_updated (só ids); as datas nunca vão para evento nem log.
module Tfd
  module RecordInpatient
    OPEN = %w[scheduled travelling].freeze

    module_function

    # -> Result.ok(tfd_case:) | fail(:missing_role | :invalid_request | :invalid_transition |
    #    :inpatient_open | :inpatient_overlap, path:, problems:)
    def call(tfd_case:, from:, by:, to: nil)
      return Result.fail(:missing_role) unless Access.committee?(by)

      starts = Transport::Support.date(from)
      ends = to.nil? ? nil : Transport::Support.date(to)
      paths = []
      paths << "from" unless starts
      paths << "to" if !to.nil? && (ends.nil? || (starts && ends < starts))
      return Transport::Support.refuse(paths) if paths.any?

      TfdCase.transaction(requires_new: true) do
        tfd_case.lock!
        next Result.fail(:invalid_transition) unless OPEN.include?(tfd_case.status)

        stays = Array(tfd_case.inpatient_stays).map { |stay| stay.slice("from", "to") }
        open = stays.find { |stay| stay["to"].nil? }
        next Transport::Support.refuse_with(:inpatient_open, "from") if open && open["from"] != starts.iso8601
        next Result.ok(tfd_case: tfd_case) if open && ends.nil?

        others = stays - [ open ].compact
        next Transport::Support.refuse_with(:inpatient_overlap, "from") if others.any? { |stay| overlap?(stay, starts, ends) }

        stays = (others + [ { "from" => starts.iso8601, "to" => ends&.iso8601 } ]).sort_by { |stay| stay["from"] }
        tfd_case.update!(inpatient_stays: stays)
        moved = Transition.call(tfd_case: tfd_case, to: nil, by: by, kind: "inpatient_recorded")
        next moved if moved.failure?

        DomainEvents.publish("tfd.case_updated", tfd_case_id: tfd_case.id, user_id: by.id)
        moved
      end
    end

    # [a, b) × [c, d) com nil = infinito; uma estada de um dia só ([d, d)) ocupa o dia d.
    def overlap?(stay, starts, ends)
      other_from = Date.iso8601(stay["from"])
      other_to = stay["to"] && Date.iso8601(stay["to"])
      starts < limit(other_from, other_to) && other_from < limit(starts, ends)
    end

    def limit(from, to) = to.nil? ? Date::Infinity.new : [ to, from + 1 ].max
    private_class_method :overlap?, :limit
  end
end
