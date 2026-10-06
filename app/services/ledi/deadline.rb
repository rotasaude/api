# LEDI competence deadline (spec §6.5; contract §8). The official SIAPS table
# wins; competences outside it use the 10th national business day of the
# following month. Pure functions: callers pass `today` already in the city's
# time zone.
module Ledi
  module Deadline
    BUSINESS_DAY = 10
    FORMAT = /\A\d{4}(0[1-9]|1[0-2])\z/
    TABLE_PATH = Rails.root.join("config/ledi/siaps_deadlines.yml")

    # Loaded once; a missing file means computation only.
    TABLE = begin
      if File.exist?(TABLE_PATH)
        (YAML.safe_load_file(TABLE_PATH, permitted_classes: [ Date ]) || {})
          .to_h { |k, v| [ k.to_s.freeze, v.to_date.freeze ] }
      else
        {}
      end
    end.freeze

    module_function

    def valid?(competence) = competence.to_s.match?(FORMAT)

    def first_day(competence) = Date.new(competence[0, 4].to_i, competence[4, 2].to_i, 1)

    # Official date when the table has it, else the estimate.
    def on(competence) = TABLE.fetch(competence.to_s) { estimated_on(competence) }

    # Always the computed date (10th business day of the following month).
    def estimated_on(competence)
      day = first_day(competence).next_month
      count = 0
      loop do
        count += 1 if Ledi::BusinessCalendar.business_day?(day)
        return day if count == BUSINESS_DAY

        day += 1
      end
    end

    def business_days_left(competence, today:)
      deadline = on(competence)
      return 0 if today > deadline

      (today..deadline).count { |day| Ledi::BusinessCalendar.business_day?(day) }
    end

    def current(today) = today.strftime("%Y%m")

    def previous(today) = today.prev_month.strftime("%Y%m")
  end
end
