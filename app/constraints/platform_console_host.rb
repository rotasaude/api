# Constraint de rota: casa requisições dirigidas ao console de plataforma
# (admin.*). Em config/routes.rb manda /session desse host para Operators::,
# e não para o SessionsController da cidade.
class PlatformConsoleHost
  def self.matches?(request)
    CityCatalog.console_host?(request.host)
  end
end
