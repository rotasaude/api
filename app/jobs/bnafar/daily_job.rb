# Remessa diária ao SI-BNAFAR (módulo 27b; contrato §3; Valor 6; R10, R19).
# Recorrente de hora em hora (minuto 7); no worker de cada cidade roda só nela
# (EachCityJob), no fuso dela. Sem argumentos.
#
#   1. sempre que a tabela existe, com o `bnafar` ligado ou não (R19): fecha a
#      janela (Window.close!: a remessa de R vira `lost` na primeira rodada de
#      R+2) e purga o payload aceito há mais de PAYLOAD_DAYS dias;
#   2. só com o `bnafar` utilizável e a partir de BUILD_HOUR (1h local): monta
#      R = ontem, no ambiente em uso, com os domínios ligados até o fim de R
#      (Gate.domains_through), enquanto alguma remessa de R não existe ou
#      ficou `building`. As rodadas seguintes da hora (e do dia) retomam o que
#      um processo morto deixou pela metade; com tudo montado, nada.
#
# Interruptores e domínios: lidos aqui, fora de transação, e passados ao Build.
module Bnafar
  class DailyJob < ApplicationJob
    prepend EachCityJob

    queue_as :housekeeping

    def perform
      city = Current.city
      return unless ApplicationRecord.connection.data_source_exists?("bnafar_submissions")

      now = Time.current
      today = Time.zone.today
      Window.close!(today: today, now: now)
      Window.purge!(now: now)

      return unless Bnafar::Gate.usable?(city)
      return if now.hour < Catalog::BUILD_HOUR

      reference_on = today - 1
      environment = Bnafar::Environment.current
      built = BnafarSubmission.where(reference_on: reference_on, environment: environment).where.not(status: "building").count
      return if built >= Catalog::SUBJECTS.size

      domains = Bnafar::Gate.domains_through(city, reference_on)
      return if domains.empty?

      Build.call(reference_on: reference_on, environment: environment, domains: domains, now: now)
    end
  end
end
