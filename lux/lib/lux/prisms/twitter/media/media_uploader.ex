defmodule Lux.Prisms.Twitter.Media.MediaUploader do
  @moduledoc """
  A prism for uploading media to Twitter — handling images, videos, and GIFs
  with chunked upload support for large files.

  ## Examples

      iex> MediaUploader.handler(%{
      ...>   action: "upload",
      ...>   file_path: "/path/to/image.png",
      ...>   media_type: "image/png"
      ...> }, %{name: "Agent"})
      {:ok, %{media_id: "123", media_type: "image/png", uploaded: true}}
  """

  use Lux.Prism,
    name: "Upload Twitter Media",
    description: "Uploads images, videos, and GIFs to Twitter with chunked upload support",
    input_schema: %{
      type: :object,
      properties: %{
        action: %{
          type: :string,
          description: "Action: upload, upload_url, get_status, chunk_upload",
          enum: ["upload", "upload_url", "get_status", "chunk_upload"]
        },
        file_path: %{
          type: :string,
          description: "Local file path to upload"
        },
        file_url: %{
          type: :string,
          description: "URL of media to upload (alternative to file_path)"
        },
        media_type: %{
          type: :string,
          description: "MIME type of the media (e.g., image/png, video/mp4, image/gif)"
        },
        media_id: %{
          type: :string,
          description: "Media ID for chunk upload continuation or status check"
        },
        alt_text: %{
          type: :string,
          description: "Alt text description for accessibility"
        },
        chunk_index: %{
          type: :integer,
          description: "Zero-based chunk index for chunked uploads"
        },
        total_chunks: %{
          type: :integer,
          description: "Total number of chunks"
        },
        chunk_data: %{
          type: :string,
          description: "Base64-encoded chunk data"
        },
        category: %{
          type: :string,
          description: "Media category: tweet_image, tweet_video, tweet_gif, dm_image, dm_video",
          enum: ["tweet_image", "tweet_video", "tweet_gif", "dm_image", "dm_video"]
        }
      },
      required: ["action"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        media_id: %{type: :string},
        media_key: %{type: :string},
        media_type: %{type: :string},
        uploaded: %{type: :boolean},
        processing_info: %{type: :object}
      },
      required: ["media_id"]
    }

  alias Lux.Integrations.Twitter.Client
  require Logger

  # Max file sizes in bytes
  @max_image_size 5 * 1024 * 1024   # 5 MB
  @max_gif_size 15 * 1024 * 1024    # 15 MB
  @max_video_size 512 * 1024 * 1024 # 512 MB

  def handler(params, agent) do
    agent_name = agent[:name] || "Unknown Agent"

    case params[:action] do
      "upload" -> upload_file(params, agent_name)
      "upload_url" -> upload_from_url(params, agent_name)
      "get_status" -> get_status(params)
      "chunk_upload" -> chunk_upload(params, agent_name)
      _ -> {:error, "Unknown action: #{params[:action]}"}
    end
  end

  defp upload_file(params, agent_name) do
    with {:ok, file_path} <- validate_required(params[:file_path], "file_path"),
         {:ok, media_type} <- validate_media_type(params[:media_type]) do

      Logger.info("Agent #{agent_name} uploading media file: #{file_path}")

      case File.stat(file_path) do
        {:ok, %{size: size}} ->
          :ok = validate_file_size(size, media_type)

          if size <= 5 * 1024 * 1024 do
            simple_upload(file_path, media_type, params[:category])
          else
            chunked_upload_file(file_path, media_type, params[:category])
          end

        {:error, :enoent} ->
          {:error, "File not found: #{file_path}"}

        {:error, reason} ->
          {:error, "Cannot read file: #{inspect(reason)}"}
      end
      |> maybe_set_alt_text(params[:alt_text])
    end
  end

  defp upload_from_url(params, agent_name) do
    with {:ok, url} <- validate_required(params[:file_url], "file_url"),
         {:ok, media_type} <- validate_media_type(params[:media_type]) do

      Logger.info("Agent #{agent_name} uploading media from URL: #{url}")

      # Download the file first
      case Req.get(url: url) do
        {:ok, %{status: 200, body: body}} ->
          # Use simple upload with the downloaded data
          category = params[:category] || infer_category(media_type)

          payload = %{
            media_data: Base.encode64(body),
            media_category: category
          }

          case Client.upload_request(:post, "/media/upload.json", %{json: payload}) do
            {:ok, %{"media_id_string" => media_id, "media_key" => media_key}} ->
              {:ok, %{media_id: media_id, media_key: media_key, media_type: media_type, uploaded: true}}

            {:ok, %{"media_id_string" => media_id}} ->
              {:ok, %{media_id: media_id, media_type: media_type, uploaded: true}}

            {:error, reason} ->
              {:error, "Failed to upload media: #{inspect(reason)}"}
          end

        {:error, reason} ->
          {:error, "Failed to download media: #{inspect(reason)}"}
      end
    end
  end

  defp get_status(params) do
    case params[:media_id] do
      nil -> {:error, "Missing media_id"}
      media_id ->
        case Client.upload_request(:get, "/media/upload.json", %{params: %{command: "STATUS", media_id: media_id}}) do
          {:ok, response} ->
            {:ok, %{media_id: media_id, processing_info: response["processing_info"]}}

          {:error, reason} ->
            {:error, "Failed to get media status: #{inspect(reason)}"}
        end
    end
  end

  defp chunk_upload(params, agent_name) do
    with {:ok, media_id} <- validate_required(params[:media_id], "media_id"),
         {:ok, chunk_index} <- validate_required(params[:chunk_index], "chunk_index"),
         {:ok, chunk_data} <- validate_required(params[:chunk_data], "chunk_data") do

      Logger.info("Agent #{agent_name} uploading chunk #{chunk_index} for media #{media_id}")

      payload = %{
        command: "APPEND",
        media_id: media_id,
        segment_index: chunk_index,
        media_data: chunk_data
      }

      case Client.upload_request(:post, "/media/upload.json", %{json: payload}) do
        {:ok, _} ->
          is_final = params[:total_chunks] && chunk_index == params[:total_chunks] - 1
          if is_final do
            finalize_upload(media_id)
          else
            {:ok, %{media_id: media_id, chunk_index: chunk_index, uploaded: false, status: "partial"}}
          end

        {:error, reason} ->
          {:error, "Chunk upload failed: #{inspect(reason)}"}
      end
    end
  end

  defp simple_upload(file_path, media_type, category) do
    {:ok, content} = File.read(file_path)
    encoded = Base.encode64(content)

    payload = %{
      media_data: encoded,
      media_category: category || infer_category(media_type)
    }

    case Client.upload_request(:post, "/media/upload.json", %{json: payload}) do
      {:ok, %{"media_id_string" => media_id, "media_key" => media_key}} ->
        {:ok, %{media_id: media_id, media_key: media_key, media_type: media_type, uploaded: true}}

      {:ok, %{"media_id_string" => media_id}} ->
        {:ok, %{media_id: media_id, media_type: media_type, uploaded: true}}

      {:error, reason} ->
        {:error, "Upload failed: #{inspect(reason)}"}
    end
  end

  defp chunked_upload_file(file_path, media_type, category) do
    {:ok, content} = File.read(file_path)
    size = byte_size(content)

    # Init
    init_payload = %{
      command: "INIT",
      total_bytes: size,
      media_type: media_type,
      media_category: category || infer_category(media_type)
    }

    case Client.upload_request(:post, "/media/upload.json", %{json: init_payload}) do
      {:ok, %{"media_id_string" => media_id}} ->
        # Upload in 4MB chunks
        chunk_size = 4 * 1024 * 1024
        chunks = chunk_binary(content, chunk_size)

        result =
          chunks
          |> Enum.with_index()
          |> Enum.reduce_while(:ok, fn {chunk, idx}, _acc ->
            payload = %{
              command: "APPEND",
              media_id: media_id,
              segment_index: idx,
              media_data: Base.encode64(chunk)
            }

            case Client.upload_request(:post, "/media/upload.json", %{json: payload}) do
              {:ok, _} -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end)

        case result do
          :ok -> finalize_upload(media_id)
          {:error, reason} -> {:error, "Chunked upload failed: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "Upload init failed: #{inspect(reason)}"}
    end
  end

  defp finalize_upload(media_id) do
    payload = %{command: "FINALIZE", media_id: media_id}

    case Client.upload_request(:post, "/media/upload.json", %{json: payload}) do
      {:ok, %{"media_id_string" => ^media_id, "processing_info" => info}} ->
        {:ok, %{media_id: media_id, uploaded: true, processing_info: info}}

      {:ok, %{"media_id_string" => ^media_id}} ->
        {:ok, %{media_id: media_id, uploaded: true}}

      {:error, reason} ->
        {:error, "Finalize failed: #{inspect(reason)}"}
    end
  end

  defp chunk_binary(binary, chunk_size) do
    if byte_size(binary) <= chunk_size do
      [binary]
    else
      <<chunk::binary-size(chunk_size), rest::binary>> = binary
      [chunk | chunk_binary(rest, chunk_size)]
    end
  end

  defp maybe_set_alt_text({:ok, result}, nil), do: {:ok, result}
  defp maybe_set_alt_text({:ok, %{media_id: media_id} = result}, alt_text) do
    payload = %{media_id: media_id, alt_text: %{text: alt_text}}
    case Client.upload_request(:post, "/media/metadata/create.json", %{json: payload}) do
      {:ok, _} -> {:ok, Map.put(result, :alt_text, alt_text)}
      {:error, _} -> {:ok, result}  # Don't fail on alt text error
    end
  end
  defp maybe_set_alt_text(error, _), do: error

  defp validate_media_type(nil), do: {:error, "Missing media_type"}
  defp validate_media_type(type) when type in ~w(image/png image/jpeg image/gif image/webp video/mp4 video/quicktime), do: {:ok, type}
  defp validate_media_type(type), do: {:ok, type}

  defp validate_file_size(size, "image/gif") when size > @max_gif_size, do: {:error, "GIF exceeds 15 MB limit"}
  defp validate_file_size(size, "video/" <> _), do: (if size > @max_video_size, do: {:error, "Video exceeds 512 MB limit"}, else: :ok)
  defp validate_file_size(size, _), do: (if size > @max_image_size, do: {:error, "Image exceeds 5 MB limit"}, else: :ok)

  defp infer_category("image/gif"), do: "tweet_gif"
  defp infer_category("video/" <> _), do: "tweet_video"
  defp infer_category(_), do: "tweet_image"

  defp validate_required(nil, field), do: {:error, "Missing #{field}"}
  defp validate_required(value, _field), do: {:ok, value}
end
