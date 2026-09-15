module CityWorkers
  # Espera antes de reiniciar um supervisor que morreu (spec §4, spike 2): um filho
  # cujo banco sumiu morre em 0,4 s e, sem espera, reiniciaria em loop apertado. A
  # espera dobra a cada falha seguida, até MAX; um filho que ficou de pé por
  # STABLE_AFTER volta a contar do começo.
  class Backoff
    BASE = 1.0
    MAX = 300.0
    STABLE_AFTER = 600.0

    def delay_for(consecutive_failures)
      return 0.0 if consecutive_failures <= 0

      [ BASE * (2**(consecutive_failures - 1)), MAX ].min
    end

    def failures_after_exit(previous_failures, ran_for:)
      ran_for >= STABLE_AFTER ? 1 : previous_failures + 1
    end
  end
end
