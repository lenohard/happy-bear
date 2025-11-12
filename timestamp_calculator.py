import datetime
import pytz


def calculate_timestamp(date_str: str, timezone_str: str = "Asia/Shanghai") -> int:
    """
    计算指定日期和时区的时间戳（毫秒）

    Args:
        date_str: 日期字符串，格式如 "2026/04/13"
        timezone_str: 时区字符串，默认为北京时间

    Returns:
        int: 毫秒级时间戳
    """
    try:
        # 解析日期
        date_obj = datetime.datetime.strptime(date_str, "%Y/%m/%d")

        # 设置时区为北京时间
        tz = pytz.timezone(timezone_str)

        # 创建带时区的日期时间对象（设置为当天0点）
        local_time = tz.localize(datetime.datetime(
            date_obj.year, date_obj.month, date_obj.day, 0, 0, 0))

        # 转换为时间戳（秒）
        timestamp_seconds = local_time.timestamp()

        # 转换为毫秒
        timestamp_milliseconds = int(timestamp_seconds * 1000)

        return timestamp_milliseconds

    except Exception as e:
        print(f"计算时间戳时出错: {e}")
        return None


def format_timestamp_info(timestamp_ms: int, timezone_str: str = "Asia/Shanghai"):
    """
    格式化显示时间戳信息

    Args:
        timestamp_ms: 毫秒级时间戳
        timezone_str: 时区字符串
    """
    if timestamp_ms is None:
        return

    # 转换为秒
    timestamp_seconds = timestamp_ms / 1000

    # 转换为UTC时间
    utc_time = datetime.datetime.fromtimestamp(
        timestamp_seconds, tz=datetime.timezone.utc)

    # 转换为北京时间
    beijing_tz = pytz.timezone(timezone_str)
    beijing_time = utc_time.astimezone(beijing_tz)

    print(f"时间戳: {timestamp_ms}")
    print(f"UTC时间: {utc_time.strftime('%Y-%m-%d %H:%M:%S %Z')}")
    print(f"北京时间: {beijing_time.strftime('%Y-%m-%d %H:%M:%S %Z')}")
    print(f"星期: {beijing_time.strftime('%A')}")


if __name__ == "__main__":
    # 计算2026年4月13日北京时间的时间戳
    target_date = "2026/04/13"
    timestamp = calculate_timestamp(target_date)

    if timestamp:
        print(f"=== {target_date} 北京时间 时间戳计算结果 ===")
        format_timestamp_info(timestamp)

        # 验证：将时间戳转换回日期验证
        print(f"\n=== 验证结果 ===")
        timestamp_seconds = timestamp / 1000
        beijing_tz = pytz.timezone("Asia/Shanghai")
        converted_time = datetime.datetime.fromtimestamp(
            timestamp_seconds, tz=beijing_tz)
        print(f"时间戳转换回日期: {converted_time.strftime('%Y/%m/%d')}")

        # 与你测试数据中的时间戳对比
        print(f"\n=== 对比参考 ===")
        test_timestamp = 1757865600000  # 你测试数据中的一个时间戳
        test_time = datetime.datetime.fromtimestamp(
            test_timestamp / 1000, tz=beijing_tz)
        print(f"测试时间戳 {test_timestamp} 对应的日期: {test_time.strftime('%Y/%m/%d')}")

    else:
        print("计算失败")
