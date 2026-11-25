# Limites do SI-BNAFAR (módulo 27b, Valor 4).
module Bnafar
  module Limits
    RECORDS_PER_BATCH = 1_000
    # A MSG46 diz 20 e o §10.3 diz 60; parte em 20 até a homologação confirmar.
    ITEMS_PER_RECORD = 20
    INCONSISTENCY_PAGE = 100
    TOKEN_MARGIN = 120 # s
    MS_THRESHOLD = 86_400
    STALE_SENDING = 10.minutes
    BACKOFF_CAP = 30.minutes
  end
end
