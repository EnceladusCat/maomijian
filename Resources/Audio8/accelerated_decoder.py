"""Use Accelerate for the dense 1D convolutions in the pinned Audio8 decoder."""

from pathlib import Path
import sys


DOMAIN = "com.maomijian.audio8"
LIBRARY = Path(__file__).with_name("audio8_conv.dylib")


class DeferredDecoder:
    def __init__(self, future):
        self.future = future

    def get_inputs(self):
        return self.future.result().get_inputs()

    def run(self, outputs, inputs):
        return self.future.result().run(outputs, inputs)


def _replace_convolutions(graph, onnx):
    weights = {item.name: item for item in graph.initializer}
    count = 0
    for node in graph.node:
        if node.domain or node.op_type not in ("Conv", "ConvTranspose") or len(node.input) != 3:
            continue
        matrix = weights.get(node.input[1])
        bias = weights.get(node.input[2])
        if matrix is None or bias is None or len(matrix.dims) != 3 or len(bias.dims) != 1:
            continue
        if matrix.data_type != onnx.TensorProto.FLOAT or bias.data_type != onnx.TensorProto.FLOAT:
            continue
        attributes = {attr.name: onnx.helper.get_attribute_value(attr) for attr in node.attribute}
        dilation = attributes.get("dilations", [1])
        stride = attributes.get("strides", [1])
        if (attributes.get("group", 1) != 1 or attributes.get("pads", [0, 0]) != [0, 0]
            or attributes.get("auto_pad", b"NOTSET") != b"NOTSET"):
            continue
        if node.op_type == "Conv":
            if matrix.dims[2] not in (1, 7) or stride != [1] or dilation not in ([1], [3], [9]):
                continue
        elif (stride not in ([2], [4], [8]) or dilation != [1] or "output_shape" in attributes
              or attributes.get("output_padding", [0]) != [0]
              or matrix.dims[2] not in (stride[0], 2 * stride[0])):
            continue
        node.domain = DOMAIN
        node.op_type = "AccelerateConv"
        del node.attribute[:]
        node.attribute.append(onnx.helper.make_attribute("dilations", dilation))
        node.attribute.append(onnx.helper.make_attribute("strides", stride))
        count += 1
    return count


def prepare_decoder(source, threads, graph_file, weights_file):
    from arktts_runtime.runtime import _session
    import onnxruntime as ort

    def options():
        settings = ort.SessionOptions()
        settings.intra_op_num_threads = threads or 1
        settings.inter_op_num_threads = 1
        settings.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
        settings.log_severity_level = 3
        settings.add_session_config_entry("session.intra_op.allow_spinning", "0")
        return settings

    providers = ["CPUExecutionProvider"]
    try:
        import onnx

        # Let ORT apply its usual FP16-to-FP32 promotions before substituting
        # kernels. This keeps the model's original precision at each boundary.
        compile_options = options()
        compile_options.optimized_model_filepath = str(graph_file)
        compile_options.add_session_config_entry(
            "session.optimized_model_external_initializers_file_name", weights_file.name)
        compile_options.add_session_config_entry(
            "session.optimized_model_external_initializers_min_size_in_bytes", "1024")
        original = ort.InferenceSession(str(source), sess_options=compile_options, providers=providers)
        graph = onnx.load_model(graph_file, load_external_data=False)
        if not _replace_convolutions(graph.graph, onnx):
            return original
        del original
        graph.opset_import.append(onnx.helper.make_opsetid(DOMAIN, 1))
        onnx.save_model(graph, graph_file)
        accelerated = options()
        accelerated.register_custom_ops_library(str(LIBRARY))
        return ort.InferenceSession(str(graph_file), sess_options=accelerated, providers=providers)
    except Exception as error:
        print(f"Audio8 accelerated decoder unavailable: {error}", file=sys.stderr)
        return _session(source, threads)
    finally:
        # The caller also owns these temporary files so a killed worker or a
        # failed job cannot leave a permanent second copy of the model weights.
        graph_file.unlink(missing_ok=True)
        weights_file.unlink(missing_ok=True)
