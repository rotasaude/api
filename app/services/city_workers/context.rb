module CityWorkers
  # A cidade deste processo quando ele é o worker de uma cidade (CityWorkers::Child,
  # Plano 5). nil no web, no console, nos specs e no worker de plataforma.
  module Context
    mattr_accessor :city_slug
  end
end
