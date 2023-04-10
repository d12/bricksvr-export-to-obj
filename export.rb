require "functions_framework"
require "google/cloud/firestore"
require "google/cloud/storage"
require "matrix"
require "zip"


firestore = Google::Cloud::Firestore.new(
  # REDACTED
)

storage = Google::Cloud::Storage.new(
  # REDACTED
)

scale_multiplier = 7.0

MIT_LICENSE = <<~LICENSE
  Copyright (c) 2021, BricksVR. All rights reserved.

  Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

  The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
LICENSE

MatColors = [
  [34, 138, 221],
  [58, 159, 73],
  [238, 129, 0],
  [224, 75, 144],
  [219, 26, 18],
  [141, 183, 49],
  [236, 208, 39],
  [10, 113, 161],
  [0, 0, 0],
  [209, 128, 86],
  [108, 50, 15],
  [0, 0, 1],
  [222, 222, 222],
  [0, 0, 0],
  [138, 138, 138],
]

FunctionsFramework.cloud_event("process-export") do |request|
  room_prefix = "v0.2-"
  room = request.data["value"]["fields"]["room"]["stringValue"]
  uuid = request.data["value"]["fields"]["uuid"]["stringValue"]
  if room.nil? || room == ""
    puts "Room code is empty"
    next "Error: Room code is empty"
  end

  if uuid.nil? || uuid == ""
    puts "UUID is empty"
    next "Error: UUID is empty"
  end

  if(room == "testfail")
    raise StandardError.new("Test failure")
  end

  puts "Processing room #{room} and uuid #{uuid}"
  puts "Downloading bricks from firestore..."

  scale_multiplier = 7.0
  bricks = []

  data_from_firestore = firestore.col("rooms").doc(room_prefix + room).col("bricks").get.map do |brick_snapshot|
    fields = brick_snapshot.fields
    bricks << {
      type: fields[:type],
      color: color_from_brick(fields[:color], fields[:matId]),
      posx: fields[:pos][:x],
      posy: fields[:pos][:y],
      posz: fields[:pos][:z],
      rotw: fields[:rot][:w],
      rotx: fields[:rot][:x],
      roty: fields[:rot][:y],
      rotz: fields[:rot][:z]
    }
  end

  puts "Loaded #{bricks.length} bricks."

  loaded_bricks = {}

  used_colors = {}
  brick_mesh_name_counter = {}

  mtl_file = "; This file is licensed under the MIT license. See included LICENSE.txt for details.\n"
  obj_file = "; This file is licensed under the MIT license. See included LICENSE.txt for details.\n"

  f_offset = 0

  obj_file << "mtllib #{room}.mtl\n"

  puts "Generating obj data..."
  bricks.each do |brick|
    w = brick[:rotw]
    x = brick[:rotx]
    y = brick[:roty]
    z = brick[:rotz]

    r = Matrix[[1 - 2*y*y - 2*z*z, 2*x*y - 2*z*w, 2*x*z + 2*y*w],
              [2*x*y + 2*z*w, 1 - 2*x*x - 2*z*z, 2*y*z - 2*x*w],
              [2*x*z - 2*y*w, 2*y*z + 2*x*w, 1 - 2*x*x - 2*y*y]]

    used_colors[brick[:color]] = true

    brick_mesh_name_counter[brick[:type]] ||= 0

    obj_file << "o #{brick[:type]} - #{brick_mesh_name_counter[brick[:type]] += 1}\n"

    number_of_vertices = 0

    loaded_bricks[brick[:type]] ||= File.read("bricks/#{brick[:type]}.pobj").lines
    loaded_bricks[brick[:type]].each do |line|
      if line[0] == "v" && line[1] == " " # vertices
        split_line = line.split(" ")

        rotated_point = r * Matrix.column_vector([split_line[1].to_f, split_line[2].to_f, split_line[3].to_f])
        obj_file << "v #{((rotated_point[0, 0] * scale_multiplier + brick[:posx])).round(4)} #{(rotated_point[1, 0] * scale_multiplier + brick[:posy]).round(4)} #{(rotated_point[2, 0] * scale_multiplier + brick[:posz]).round(4)}\n"

        number_of_vertices += 1
      elsif line[0] == "v" && line[1] == "n" # vertex normals
        split_line = line.split(" ")

        rotated_point = r * Matrix.column_vector([split_line[1].to_f, split_line[2].to_f, split_line[3].to_f])
        obj_file << "vn #{((rotated_point[0, 0] * scale_multiplier + brick[:posx])).round(4)} #{((rotated_point[1, 0] * scale_multiplier + brick[:posy])).round(4)} #{((rotated_point[2, 0] * scale_multiplier + brick[:posz])).round(4)}\n"
      elsif line[0] == "u" # usemtl
        obj_file << "usemtl #{brick[:color].join("")}\n"
      elsif line[0] == "f" # faces
        num_1 = line.split("/")[1].to_i + f_offset
        num_2 = line.split("/")[3].to_i + f_offset
        num_3 = line.split("/")[5].to_i + f_offset
        obj_file << "f #{num_1}/#{num_1}/#{num_1} #{num_2}/#{num_2}/#{num_2} #{num_3}/#{num_3}/#{num_3}\n"
      else
        obj_file << line # vertex texture coordinates can be copied as-is since they aren't relative to anything else
      end
    end
    f_offset += number_of_vertices
  end

  used_colors.each do |color, _|
    mtl_file << "newmtl #{color.join("")}\n"
    mtl_file << "Ka 1.000 1.000 1.000\n"
    mtl_file << "Kd #{color[0] / 255.0} #{color[1] / 255.0} #{color[2] / 255.0}\n"
    mtl_file << "Ks 0.100 0.100 0.100\n"
    mtl_file << "Ns 10.000\n"
    mtl_file << "illum 2\n"
  end

  puts "Writing files to tmp/..."
  obj_tmp_file = Tempfile.new("tmp_obj")
  mtl_tmp_file = Tempfile.new("tmp_mtl")
  license_file = Tempfile.new("license")

  File.open(obj_tmp_file.path, "w") do |file|
    file.write(obj_file)
  end

  File.open(mtl_tmp_file.path, "w") do |file|
    file.write(mtl_file)
  end

  File.open(license_file.path, "w") do |file|
    file.write(MIT_LICENSE)
  end

  puts "Zipping files..."

  zip_tmp_file = Tempfile.new
  Zip::File.open(zip_tmp_file.path, Zip::File::CREATE) do |zip_file|
    zip_file.add("#{room}.obj", obj_tmp_file.path)
    zip_file.add("#{room}.mtl", mtl_tmp_file.path)
    zip_file.add("LICENSE.txt", license_file.path)
  end

  puts "Uploading files..."
  bucket = storage.bucket "bricksvr-world-obj-exports"
  zip_cloud_storage_file = bucket.create_file(zip_tmp_file.path, "#{uuid}.zip")

  puts "ZIP: #{zip_cloud_storage_file.media_url}"

  puts "Updating export object in firestore..."
  firestore.col("exports").doc(uuid).set({
    completed_at: Google::Cloud::Firestore::FieldValue.server_time,
    status: "completed",
    zip_url: zip_cloud_storage_file.media_url,
  }, merge: true)


  zip_tmp_file.close
  zip_tmp_file.unlink
  puts "Finished."
rescue StandardError => e
  puts "Hit an error:"
  puts e
  puts e.backtrace

  # set firestore export to failed state
  firestore.col("exports").doc(uuid).set({
    completed_at: Google::Cloud::Firestore::FieldValue.server_time,
    status: "failed",
  }, merge: true)

  puts "Succesfully set export to failed state."
end

def color_from_brick(color, matId)
  if color
    [(color >> 16) & 0xFF, (color >> 8) & 0xFF, color & 0xFF]
  else
    MatColors[matId]
  end
end
