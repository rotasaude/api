require Rails.root.join("db/solid_queue_tables").to_s

# Fila de PLATAFORMA (spec banco-por-cidade §4, Plano 5): jobs de ciclo de vida —
# provisionamento, e-mail do convite, purga de acesso. Só PlatformQueue::JOBS
# entram aqui; nunca dado de cidadão. Aditiva.
class CreatePlatformSolidQueueTables < ActiveRecord::Migration[8.1]
  def change
    SolidQueueTables.create(self)
  end
end
