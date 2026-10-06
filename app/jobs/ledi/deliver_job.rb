# Entrega as fichas pendentes da fila LEDI de cada cidade. Esqueleto: a Task 8
# preenche o corpo. Recorrente, sem argumento.
module Ledi
  class DeliverJob < ApplicationJob
    prepend EachCityJob

    queue_as :default

    def perform; end
  end
end
