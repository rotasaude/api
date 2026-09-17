# Constraint de rota: casa requisições dirigidas à API de manutenção
# (maintenance-api.*), irmã de PlatformConsoleHost. Casada com
# MaintenanceApi.enabled?, que decide se a rota chega a ser desenhada.
class MaintenanceApiHost
  def self.matches?(request)
    CityCatalog.maintenance_api_host?(request.host)
  end
end
