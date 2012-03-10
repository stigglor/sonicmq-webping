require './app'

# Compass Configuration

# Configuration to use when running within Sinatra
project_path          = Sinatra::Application.root

# HTTP paths
http_path             = '/'
http_stylesheets_path = '/stylesheets'
http_images_path      = '/images'
http_javascripts_path = '/javascripts'

# File system locations
css_dir               = File.join 'static', 'stylesheets'
sass_dir              = File.join 'views', 'stylesheets'
images_dir            = File.join 'static', 'images'
javascripts_dir       = File.join 'static', 'javascripts'
