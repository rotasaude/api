# Job diário das sugestões (ADR 0040; spec §4). Por cidade (EachCityJob),
# só com care_lines ligado e utilizável. Log só com contagens.
module CareLines
  class SuggestJob < ApplicationJob
    prepend EachCityJob
    queue_as :housekeeping

    def perform
      return unless Gate.usable?(Current.city)

      result = Suggest.run(today: Time.zone.today)
      Rails.logger.info("[CareLines::SuggestJob] city=#{Current.city.slug} created=#{result[:created]} closures=#{result[:closures]}")
    end
  end
end
