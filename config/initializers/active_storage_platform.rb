# Active Storage mora no banco da plataforma (spec identidade da cidade §4.1).
# Sem isto o ActiveStorage::Record usaria a conexão padrão (cidade).
# draw_routes = false está em config/application.rb: as rotas /rails/active_storage
# não existem; o brasão é servido por um controller próprio.
ActiveSupport.on_load(:active_storage_record) do
  connects_to database: { writing: :platform, reading: :platform }
end
