# Enfileirar um job de PLATAFORMA dentro de um exemplo (Plano 5). O harness roda
# todo exemplo dentro de CityConnection.with(TEST_CITY_A), então a fila de destino
# num spec é a da cidade — e PlatformQueue recusa job de plataforma ali. Este
# helper leva só o SolidQueue::Record de volta ao shard padrão (a fila de
# plataforma), como acontece no console e no worker de plataforma.
module PlatformQueueHelpers
  def on_platform_queue(&block)
    SolidQueue::Record.connected_to(role: :writing, shard: SolidQueue::Record.default_shard, &block)
  end
end

RSpec.configure do |config|
  config.include PlatformQueueHelpers
end
